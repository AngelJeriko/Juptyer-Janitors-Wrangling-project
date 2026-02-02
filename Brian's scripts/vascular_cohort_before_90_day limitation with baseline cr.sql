-- ------------------------------------------------------------------
-- STEP 1: CREATE THE PERMANENT BASELINE TABLE
-- ------------------------------------------------------------------
DROP TABLE IF EXISTS vascular_cohort_with_baseline;

CREATE TABLE vascular_cohort_with_baseline AS
WITH ranked_baselines AS (
    SELECT 
        vc.hadm_id,
        vc.subject_id,
        vc.admittime,
        le.valuenum as lab_value,
        le.charttime,
        
        -- PRIORITY LOGIC
        CASE 
            -- Priority 1: Recent (-7 to -1 days)
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 7) 
             AND le.charttime::DATE < vc.admittime::DATE 
            THEN 1
            
            -- Priority 2: Day of Surgery (Day 0)
            WHEN le.charttime::DATE = vc.admittime::DATE 
            THEN 2
            
            -- Priority 3: Remote (-365 to -8 days)
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 365) 
             AND le.charttime::DATE <= (vc.admittime::DATE - 8)
            THEN 3
            
            ELSE 4 
        END as priority_rank
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        AND le.charttime >= (vc.admittime - INTERVAL '365 days')
        AND le.charttime <= vc.admittime
),
best_baseline AS (
    SELECT 
        hadm_id,
        subject_id,
        admittime,
        -- Select the BEST single value using array logic
        (ARRAY_AGG(lab_value ORDER BY priority_rank ASC, charttime DESC))[1] as baseline_creatinine,
        
        -- Label the source
        CASE 
            WHEN min(priority_rank) = 1 THEN 'Recent'
            WHEN min(priority_rank) = 2 THEN 'Day0'
            WHEN min(priority_rank) = 3 THEN 'Remote'
            ELSE 'Missing'
        END as data_source
    FROM ranked_baselines
    GROUP BY hadm_id, subject_id, admittime
)
SELECT * FROM best_baseline;


select * from vascular_cohort_with_baseline;


--#########################--
-- ------------------------------------------------------------------
-- STEP 2: CALCULATE KDIGO AKI STAGES
-- ------------------------------------------------------------------
WITH post_op_max AS (
    SELECT 
        vc.hadm_id,
        vc.baseline_creatinine,
        vc.data_source,
        -- Find the highest Creatinine in the 7 days after surgery
        MAX(le.valuenum) as max_postop_cr
    FROM vascular_cohort_with_baseline vc
    LEFT JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        
        -- DYNAMIC START TIME (The Safety Lock)
        AND le.charttime::DATE >= CASE 
            WHEN vc.data_source = 'Day0' THEN (vc.admittime::DATE + 1)
            ELSE vc.admittime::DATE
        END
        
        -- END TIME: 7 Days after surgery
        AND le.charttime::DATE <= (vc.admittime::DATE + 7)
        
    WHERE vc.baseline_creatinine IS NOT NULL -- Exclude the 950 missing
    GROUP BY vc.hadm_id, vc.baseline_creatinine, vc.data_source
)

SELECT 
    CASE 
        -- Stage 3: 3x baseline OR Increase to >= 4.0 mg/dL with acute rise
        WHEN (max_postop_cr / baseline_creatinine) >= 3.0 
          OR (max_postop_cr >= 4.0 AND (max_postop_cr - baseline_creatinine) >= 0.3) 
        THEN 3
        
        -- Stage 2: 2x to 2.9x baseline
        WHEN (max_postop_cr / baseline_creatinine) >= 2.0 
        THEN 2
        
        -- Stage 1: 1.5x baseline OR Absolute Increase >= 0.3 mg/dL
        WHEN (max_postop_cr / baseline_creatinine) >= 1.5 
          OR (max_postop_cr - baseline_creatinine) >= 0.3 
        THEN 1
        
        ELSE 0 
    END as aki_stage,
    
    COUNT(*) as patient_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) as percentage
FROM post_op_max
GROUP BY 1
ORDER BY 1 DESC;
-- ------------------------------------------------------------------
-- TITLE: MASTER_VASCULAR_AKI_LOGIC
-- DESCRIPTION: 1. Builds Baseline (Recent > Day0 > Remote)
--              2. Calculates AKI (KDIGO Stages)
-- ------------------------------------------------------------------

WITH ranked_baselines AS (
    -- STEP 1: FIND ALL POTENTIAL BASELINES
    SELECT 
        vc.hadm_id,
        vc.subject_id,
        vc.admittime,
        le.valuenum as lab_value,
        le.charttime,
        
        -- Assign Priority
        CASE 
            -- Priority 1: Recent (Gold) - Day -1 to -7
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 7) 
             AND le.charttime::DATE < vc.admittime::DATE 
            THEN 1
            
            -- Priority 2: Day of Surgery (Silver) - Day 0
            WHEN le.charttime::DATE = vc.admittime::DATE 
            THEN 2
            
            -- Priority 3: Remote (Bronze) - Day -8 to -90
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 90) 
             AND le.charttime::DATE <= (vc.admittime::DATE - 8)
            THEN 3
            
            ELSE 4 
        END as priority_rank
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        AND le.charttime >= (vc.admittime - INTERVAL '90 days')
        AND le.charttime <= vc.admittime
),
best_baseline AS (
    -- STEP 2: SELECT THE SINGLE BEST BASELINE PER PATIENT
    SELECT 
        hadm_id,
        subject_id,
        admittime,
        -- Pick the lab with the lowest Rank (1 is best)
        -- If ties (e.g. 2 labs on same day), pick the latest one (charttime DESC)
        (ARRAY_AGG(lab_value ORDER BY priority_rank ASC, charttime DESC))[1] as baseline_creatinine,
        
        CASE 
            WHEN min(priority_rank) = 1 THEN 'Recent'
            WHEN min(priority_rank) = 2 THEN 'Day0'
            WHEN min(priority_rank) = 3 THEN 'Remote'
            ELSE 'Missing'
        END as data_source
    FROM ranked_baselines
    GROUP BY hadm_id, subject_id, admittime
),
post_op_max AS (
    -- STEP 3: FIND PEAK POST-OP CREATININE
    SELECT 
        bb.hadm_id,
        bb.baseline_creatinine,
        bb.data_source,
        MAX(le.valuenum) as max_postop_cr
    FROM best_baseline bb
    LEFT JOIN mimiciv_hosp.labevents le 
        ON bb.subject_id = le.subject_id 
        AND le.itemid = 50912 
        AND le.valuenum IS NOT NULL
        
        -- DYNAMIC START TIME:
        -- If Baseline was 'Day0', start looking on Day 1 (Post-op Day 1)
        -- Otherwise start looking on Day 0 (Post-op Day 0)
        AND le.charttime::DATE >= CASE 
            WHEN bb.data_source = 'Day0' THEN (bb.admittime::DATE + 1)
            ELSE bb.admittime::DATE
        END
        
        -- END TIME: 7 Days after surgery
        AND le.charttime::DATE <= (bb.admittime::DATE + 7)
        
    WHERE bb.baseline_creatinine IS NOT NULL -- Exclude the missing people
    GROUP BY bb.hadm_id, bb.baseline_creatinine, bb.data_source
)

-- STEP 4: CALCULATE FINAL STAGES
SELECT 
    CASE 
        -- Stage 3
        WHEN (max_postop_cr / baseline_creatinine) >= 3.0 
          OR (max_postop_cr >= 4.0 AND (max_postop_cr - baseline_creatinine) >= 0.3) 
        THEN 3
        
        -- Stage 2
        WHEN (max_postop_cr / baseline_creatinine) >= 2.0 
        THEN 2
        
        -- Stage 1
        WHEN (max_postop_cr / baseline_creatinine) >= 1.5 
          OR (max_postop_cr - baseline_creatinine) >= 0.3 
        THEN 1
        
        ELSE 0 
    END as aki_stage,
    
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) as percentage

FROM post_op_max
GROUP BY 1
ORDER BY 1 DESC;
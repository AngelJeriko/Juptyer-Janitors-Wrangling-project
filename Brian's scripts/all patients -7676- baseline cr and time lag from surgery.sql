-- ------------------------------------------------------------------
-- TITLE: FIGURE_1_DATA_GENERATION
-- DESCRIPTION: Extracts Baseline Cr and Time-Lag for ALL 7,676 patients
-- ------------------------------------------------------------------

WITH all_candidate_labs AS (
    SELECT 
        vc.hadm_id,
        vc.admittime,
        le.valuenum as lab_value,
        le.charttime,
        
        -- Calculate Exact Lag in Days (Negative = Pre-op)
        -- We use casting to numeric for precision
        EXTRACT(EPOCH FROM (le.charttime - vc.admittime)) / 86400.0 as days_diff_float,
        
        -- Apply the Hierarchy to pick the "Winner" Lab
        CASE 
            -- 1. Recent (-7 to -1)
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 7) 
             AND le.charttime::DATE < vc.admittime::DATE 
            THEN 1
            
            -- 2. Day 0
            WHEN le.charttime::DATE = vc.admittime::DATE 
            THEN 2
            
            -- 3. Remote (Anything else up to 365 days)
            WHEN le.charttime >= (vc.admittime - INTERVAL '365 days')
             AND le.charttime <= vc.admittime
            THEN 3
            
            ELSE 4
        END as priority
    FROM vascular_cohort vc
    LEFT JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        AND le.charttime >= (vc.admittime - INTERVAL '365 days')
        AND le.charttime <= vc.admittime
),
best_baseline_per_patient AS (
    SELECT DISTINCT ON (hadm_id)
        hadm_id,
        lab_value as baseline_creatinine,
        days_diff_float as days_from_surgery,
        
        CASE 
            WHEN priority = 1 THEN 'Recent'
            WHEN priority = 2 THEN 'Day0'
            WHEN priority = 3 THEN 'Remote'
            ELSE 'Error'
        END as source_label
    FROM all_candidate_labs
    WHERE priority <= 3
    ORDER BY hadm_id, priority ASC, charttime DESC -- Tie-break: Best priority, then latest time
)

-- JOIN BACK TO FULL COHORT TO ENSURE N=7676 (Include Missing)
SELECT 
    vc.hadm_id,
    COALESCE(bb.baseline_creatinine, NULL) as baseline_creatinine,
    
    -- Round days for cleaner plotting, but keep 1 decimal
    ROUND(bb.days_from_surgery::NUMERIC, 2) as days_from_surgery,
    
    COALESCE(bb.source_label, 'Missing') as data_source
FROM vascular_cohort vc
LEFT JOIN best_baseline_per_patient bb ON vc.hadm_id = bb.hadm_id
ORDER BY days_from_surgery DESC;
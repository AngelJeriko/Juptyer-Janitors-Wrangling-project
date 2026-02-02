-- ------------------------------------------------------------------
-- TITLE: FINAL_BASELINE_CONSTRUCTION
-- DESCRIPTION: Coalesces pre-op data based on MAE validation (Recent > Day0 > Remote)
-- ------------------------------------------------------------------

WITH ranked_labs AS (
    SELECT 
        vc.hadm_id,
        le.valuenum as lab_value,
        le.charttime,
        vc.admittime,
        -- Calculate the "Days Prior" for reference
        (le.charttime::DATE - vc.admittime::DATE) as days_diff,
        
        -- ASSIGN PRIORITY BASED ON AUDIT RESULTS
        CASE 
            -- Priority 1: Recent (Gold Standard)
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 7) 
             AND le.charttime::DATE < vc.admittime::DATE 
            THEN 1
            
            -- Priority 2: Day of Surgery (Silver Standard - MAE 0.30)
            WHEN le.charttime::DATE = vc.admittime::DATE 
            THEN 2
            
            -- Priority 3: Remote (Bronze Standard - MAE 0.63)
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 365) 
             AND le.charttime::DATE <= (vc.admittime::DATE - 8)
            THEN 3
            
            ELSE 4 -- Out of window
        END as priority_rank
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        AND le.charttime >= (vc.admittime - INTERVAL '365 days')
        AND le.charttime <= vc.admittime
)

SELECT 
    vc.hadm_id,
    
    -- 1. The Chosen Value
    MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 1) as cr_recent,
    MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 2) as cr_day0,
    MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 3) as cr_remote,
    
    -- 2. The Final Coalesced Column (This is your model input)
    COALESCE(
        MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 1), -- Try Recent
        MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 2), -- Fallback to Day 0
        MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 3)  -- Last resort Remote
    ) as baseline_creatinine,
    
    -- 3. The Source Flag (For your "Limitations" section)
    CASE 
        WHEN MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 1) IS NOT NULL THEN 'Recent'
        WHEN MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 2) IS NOT NULL THEN 'Day0'
        WHEN MAX(rl.lab_value) FILTER (WHERE rl.priority_rank = 3) IS NOT NULL THEN 'Remote'
        ELSE 'Missing'
    END as data_source

FROM vascular_cohort vc
LEFT JOIN ranked_labs rl ON vc.hadm_id = rl.hadm_id
GROUP BY vc.hadm_id;
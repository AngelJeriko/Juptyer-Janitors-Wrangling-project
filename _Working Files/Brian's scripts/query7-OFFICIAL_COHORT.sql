-- ------------------------------------------------------------------
-- TITLE: STRICT_BASELINE_COHORT (90-DAY LIMIT)
-- DESCRIPTION: Re-builds the cohort. Drops Missing. Drops >90 Day Remote.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS vascular_cohort_strict;

CREATE TABLE vascular_cohort_strict AS
WITH ranked_baselines AS (
    SELECT 
        vc.hadm_id,
        vc.subject_id,
        vc.admittime,
        le.valuenum as lab_value,
        le.charttime,
        
        -- PRIORITY LOGIC (Updated)
        CASE 
            -- Priority 1: Recent (-1 to -7 days)
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 7) 
             AND le.charttime::DATE < vc.admittime::DATE 
            THEN 1
            
            -- Priority 2: Day of Surgery (Day 0)
            WHEN le.charttime::DATE = vc.admittime::DATE 
            THEN 2
            
            -- Priority 3: STRICT REMOTE (-8 to -90 days ONLY)
            -- We changed the window from 365 to 90
            WHEN le.charttime::DATE >= (vc.admittime::DATE - 90) 
             AND le.charttime::DATE <= (vc.admittime::DATE - 8)
            THEN 3
            
            ELSE 4 -- Anything older than 90 days is now 'Priority 4' (Ignored)
        END as priority_rank
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        -- Hard Filter: Only look back 90 days max
        AND le.charttime >= (vc.admittime - INTERVAL '90 days')
        AND le.charttime <= vc.admittime
),
best_baseline AS (
    SELECT 
        hadm_id,
        subject_id,
        admittime,
        -- Select the BEST single value
        (ARRAY_AGG(lab_value ORDER BY priority_rank ASC, charttime DESC))[1] as baseline_creatinine,
        
        -- Label the source
        CASE 
            WHEN min(priority_rank) = 1 THEN 'Recent'
            WHEN min(priority_rank) = 2 THEN 'Day0'
            WHEN min(priority_rank) = 3 THEN 'Remote (<90d)'
            ELSE 'Missing'
        END as data_source
    FROM ranked_baselines
    GROUP BY hadm_id, subject_id, admittime
)

-- FINAL FILTER: Drop the Missing
SELECT * FROM best_baseline
WHERE baseline_creatinine IS NOT NULL;
-- ------------------------------------------------------------------
-- TITLE: BASELINE_CREATININE_HIERARCHY
-- DESCRIPTION: Stratifies patients into 4 mutually exclusive groups
-- ------------------------------------------------------------------

WITH raw_flags AS (
    SELECT 
        vc.hadm_id,
        -- Convert timestamps to dates for clean day-level buckets
        vc.admittime::DATE as surgery_date,
        le.charttime::DATE as lab_date,
        le.valuenum
    FROM vascular_cohort vc
    LEFT JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Serum Creatinine
        AND le.valuenum IS NOT NULL
        -- Broad lookback: 1 year prior up to day of surgery
        AND le.charttime >= (vc.admittime - INTERVAL '365 days')
        AND le.charttime <= vc.admittime
),
patient_categories AS (
    SELECT 
        hadm_id,
        -- Create Binary Flags for each window (Overlaps allowed here)
        MAX(CASE 
            WHEN lab_date >= (surgery_date - 7) AND lab_date < surgery_date 
            THEN 1 ELSE 0 
        END) as has_recent_7_to_1,
        
        MAX(CASE 
            WHEN lab_date >= (surgery_date - 365) AND lab_date < (surgery_date - 7) 
            THEN 1 ELSE 0 
        END) as has_remote_365_to_8,
        
        MAX(CASE 
            WHEN lab_date = surgery_date 
            THEN 1 ELSE 0 
        END) as has_day_of_surgery
    FROM raw_flags
    GROUP BY hadm_id
)

SELECT 
    COUNT(*) as total_patients,

    -- GROUP 1: PREFERRED (Recent: Day -1 to -7)
    SUM(has_recent_7_to_1) as group_1_recent_count,
    ROUND(SUM(has_recent_7_to_1) * 100.0 / COUNT(*), 1) as pct_recent,

    -- GROUP 2: RESCUE (Remote: Day -8 to -365)
    -- Logic: Has Remote BUT DOES NOT have Recent
    SUM(CASE 
        WHEN has_remote_365_to_8 = 1 AND has_recent_7_to_1 = 0 
        THEN 1 ELSE 0 
    END) as group_2_remote_only_count,

    -- GROUP 3: LAST RESORT (Day of Surgery: Day 0)
    -- Logic: Has Day 0 BUT DOES NOT have Recent OR Remote
    SUM(CASE 
        WHEN has_day_of_surgery = 1 AND has_recent_7_to_1 = 0 AND has_remote_365_to_8 = 0 
        THEN 1 ELSE 0 
    END) as group_3_day0_only_count,

    -- GROUP 4: MISSING
    -- Logic: Has NONE of the above
    SUM(CASE 
        WHEN has_recent_7_to_1 = 0 AND has_remote_365_to_8 = 0 AND has_day_of_surgery = 0 
        THEN 1 ELSE 0 
    END) as group_4_no_preop_cr

FROM patient_categories;
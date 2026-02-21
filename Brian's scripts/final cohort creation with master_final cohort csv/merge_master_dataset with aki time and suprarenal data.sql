-- ------------------------------------------------------------------
-- TITLE: APPEND_NEW_FEATURES_TO_MASTER
-- DESCRIPTION: Takes the existing master dataset and strictly appends 
--              the suprarenal clamp and time-resolved AKI columns.
-- ------------------------------------------------------------------
DROP TABLE IF EXISTS master_vascular_dataset_final;

CREATE TABLE master_vascular_dataset_final AS
SELECT 
    m.*,  -- Keeps every column you already successfully built
    
    -- Bolt on the Anatomical Confounder
    COALESCE(sc.suprarenal_clamp_flag, 0) as suprarenal_clamp_flag,

    -- Bolt on the Time-Resolved AKI Windows
    COALESCE(atw.aki_24h_flag, 0) as aki_24h_flag,
    COALESCE(atw.aki_72h_flag, 0) as aki_72h_flag,
    COALESCE(atw.aki_7day_flag, 0) as aki_7day_flag,
    atw.time_to_aki_days

FROM master_vascular_dataset m
LEFT JOIN suprarenal_clamp_summary sc ON m.hadm_id = sc.hadm_id
LEFT JOIN aki_time_windows_summary atw ON m.hadm_id = atw.hadm_id;
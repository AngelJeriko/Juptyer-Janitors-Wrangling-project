-- ------------------------------------------------------------------
-- TITLE: CREATE_MASTER_VASCULAR_DATASET_FINAL_V4 (Fixed Columns)
-- DESCRIPTION: Merges all 6 categories using the CORRECT column names
--              from the Broad Dragnet and TWA tables.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS master_vascular_dataset;

CREATE TABLE master_vascular_dataset AS
SELECT 
    -- 1. BASE COHORT & DEMOGRAPHICS (Source: Patients)
    p.subject_id,
    p.hadm_id,
    p.age,
    p.gender,
    p.race,
    p.procedure_group,
    p.baseline_creatinine,
    p.baseline_class_id,

    -- 2. HEMODYNAMICS (Source: hemo_pressor_summary & map_twa_summary)
    COALESCE(twa.map_twa_24h, h.map_avg_24h) as map_twa_24h, -- Priority to TWA
    h.map_avg_24h as map_arithmetic_mean,
    h.map_min_24h,
    h.map_variance,
    h.map_count_below_65,
    h.map_count_below_75,
    h.hr_admit,
    h.vasopressor_flag,
    h.pressor_hours,
    h.max_pressor_dose,

    -- 3. RENAL OUTCOMES (Source: renal_fluid_summary)
    r.aki_stage_24h,
    r.aki_flag,
    r.urine_output_24h,
    r.total_fluid_intake_24h,
    r.fluid_balance_24h,

    -- 4. CLINICAL RISK PROFILE (Source: comorbidity_summary)
    c.charlson_comorbidity_index as charlson_score,
    c.elixhauser_vanwalraven_score as elixhauser_score,
    c.chf as hx_chf,
    c.pvd as hx_pvd,
    c.copd as hx_copd,
    c.dm_comp as hx_diabetes_comp,
    c.htn_comp as hx_hypertension_comp,
    c.renal as hx_ckd,
    c.liver_mild, c.liver_sev, c.metastatic, c.coag, c.obesity, 

    -- 5. LABS & VITALS (Source: lab_vital_dragnet)
    -- Chemistry
    l.sodium_mean, l.potassium_mean, l.chloride_mean, l.bicarbonate_mean,
    l.aniongap_mean, l.glucose_mean, l.bun_mean, l.calcium_mean, 
    l.magnesium_mean, l.phosphate_mean,
    -- Hematology/Coag
    l.wbc_mean, l.platelets_mean, l.rdw_mean, l.pt_mean, l.inr_mean, l.fibrinogen_mean,
    -- Shock/Liver
    l.lactate_mean, l.lactate_max, l.bilirubin_mean, l.albumin_mean, l.alt_mean, l.ast_mean,
    -- Vital Variability
    l.hr_mean, l.hr_sd,
    l.rr_mean, l.rr_sd,
    l.spo2_mean, l.spo2_sd,
    l.temp_mean, l.temp_sd,

    -- 6. SAFETY & SURVIVAL (Source: safety_survival_summary)
    s.peak_troponin,
    s.myocardial_injury_flag,
    s.min_hgb_48h,
    s.transfusion_event,
    s.hospital_expire_flag,
    s.discharge_location,
    s.date_of_death,
    s.time_to_death_days,
    s.icu_los_days,
    s.hospital_los_days

FROM Patients p
LEFT JOIN hemo_pressor_summary h ON p.hadm_id = h.hadm_id
LEFT JOIN renal_fluid_summary r ON p.hadm_id = r.hadm_id
LEFT JOIN comorbidity_summary c ON p.hadm_id = c.hadm_id
LEFT JOIN lab_vital_dragnet l ON p.hadm_id = l.hadm_id
LEFT JOIN safety_survival_summary s ON p.hadm_id = s.hadm_id
LEFT JOIN map_twa_summary twa ON p.hadm_id = twa.hadm_id
ORDER BY p.subject_id;
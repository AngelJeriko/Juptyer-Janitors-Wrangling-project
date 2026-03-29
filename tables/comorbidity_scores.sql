-- ------------------------------------------------------------------
-- TITLE: CREATE_COMORBIDITY_SUMMARY_FINAL_V2
-- DESCRIPTION: Calculates CCI and ECI. Explicitly lists flags to 
--              prevent "Column specified more than once" errors.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS comorbidity_summary;

CREATE TABLE comorbidity_summary AS
WITH raw_flags AS (
    SELECT 
        hadm_id,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I50%') OR (icd_version=9 AND icd_code LIKE '428%') THEN 1 ELSE 0 END) as chf,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I4%') OR (icd_version=9 AND icd_code BETWEEN '4270' AND '4279') THEN 1 ELSE 0 END) as arrhythmias,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'I05%' OR icd_code LIKE 'I3%')) OR (icd_version=9 AND (icd_code LIKE '394%' OR icd_code LIKE '424%')) THEN 1 ELSE 0 END) as valvular,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I26%' OR icd_code LIKE 'I27%') OR (icd_version=9 AND icd_code LIKE '415%' OR icd_code LIKE '416%') THEN 1 ELSE 0 END) as pulm_circ,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I70%') OR (icd_version=9 AND icd_code LIKE '440%') THEN 1 ELSE 0 END) as pvd,
        MAX(CASE WHEN (icd_version=10 AND icd_code IN ('I10')) OR (icd_version=9 AND icd_code = '4011' OR icd_code = '4019') THEN 1 ELSE 0 END) as htn_uncomp,
        MAX(CASE WHEN (icd_version=10 AND icd_code BETWEEN 'I11' AND 'I15') OR (icd_version=9 AND icd_code BETWEEN '402' AND '405') THEN 1 ELSE 0 END) as htn_comp,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'G8%') OR (icd_version=9 AND (icd_code LIKE '342%' OR icd_code LIKE '344%')) THEN 1 ELSE 0 END) as paralysis,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'G1%' OR icd_code LIKE 'G2%' OR icd_code LIKE 'G3%')) OR (icd_version=9 AND (icd_code LIKE '33%' OR icd_code LIKE '340%')) THEN 1 ELSE 0 END) as neuro,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'J4%') OR (icd_version=9 AND icd_code BETWEEN '490' AND '496') THEN 1 ELSE 0 END) as copd,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E1%9') OR (icd_version=9 AND (icd_code LIKE '2500%' OR icd_code LIKE '2501%')) THEN 1 ELSE 0 END) as dm_uncomp,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'E10%' AND icd_code NOT LIKE '%9')) OR (icd_version=9 AND (icd_code LIKE '2504%' OR icd_code LIKE '2505%' OR icd_code LIKE '2506%' OR icd_code LIKE '2507%')) THEN 1 ELSE 0 END) as dm_comp,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E0%') OR (icd_version=9 AND icd_code LIKE '244%') THEN 1 ELSE 0 END) as thyroid,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'N18%') OR (icd_version=9 AND icd_code LIKE '585%') THEN 1 ELSE 0 END) as renal,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'K703%' OR icd_code LIKE 'K73%' OR icd_code LIKE 'K746%')) OR (icd_version=9 AND (icd_code LIKE '5712%' OR icd_code LIKE '5715%' OR icd_code LIKE '5716%')) THEN 1 ELSE 0 END) as liver_mild,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'I85%' OR icd_code LIKE 'K72%')) OR (icd_version=9 AND (icd_code LIKE '4560%' OR icd_code LIKE '4561%' OR icd_code LIKE '5722%')) THEN 1 ELSE 0 END) as liver_sev,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'K2%') OR (icd_version=9 AND icd_code LIKE '53%') THEN 1 ELSE 0 END) as pud,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'B20%') OR (icd_version=9 AND icd_code LIKE '042%') THEN 1 ELSE 0 END) as hiv,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'C8%') OR (icd_version=9 AND icd_code BETWEEN '200' AND '202') THEN 1 ELSE 0 END) as lymphoma,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'C7%') OR (icd_version=9 AND icd_code LIKE '19%') THEN 1 ELSE 0 END) as metastatic,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'C%') AND (icd_code NOT LIKE 'C7%') OR (icd_version=9 AND icd_code BETWEEN '140' AND '189') THEN 1 ELSE 0 END) as solid_tumor,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'M05%' OR icd_code LIKE 'M06%') OR (icd_version=9 AND (icd_code LIKE '710%' OR icd_code LIKE '714%')) THEN 1 ELSE 0 END) as rheum,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'D6%') OR (icd_version=9 AND icd_code LIKE '286%') THEN 1 ELSE 0 END) as coag,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E66%') OR (icd_version=9 AND icd_code LIKE '2780%') THEN 1 ELSE 0 END) as obesity,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'R63%') OR (icd_version=9 AND icd_code LIKE '7832%') THEN 1 ELSE 0 END) as weight_loss,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E87%') OR (icd_version=9 AND icd_code LIKE '276%') THEN 1 ELSE 0 END) as electrolytes,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'D5%') OR (icd_version=9 AND icd_code LIKE '280%') THEN 1 ELSE 0 END) as anemia_def,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'F10%') OR (icd_version=9 AND (icd_code LIKE '291%' OR icd_code LIKE '303%')) THEN 1 ELSE 0 END) as alcohol,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'F11%' OR icd_code LIKE 'F12%') OR (icd_version=9 AND icd_code LIKE '304%') THEN 1 ELSE 0 END) as drugs,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'F2%') OR (icd_version=9 AND icd_code LIKE '295%') THEN 1 ELSE 0 END) as psychoses,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'F32%' OR icd_code LIKE 'F33%')) OR (icd_version=9 AND (icd_code LIKE '3004%' OR icd_code LIKE '311%')) THEN 1 ELSE 0 END) as depression
    FROM mimiciv_hosp.diagnoses_icd
    GROUP BY hadm_id
)

SELECT 
    p.subject_id,
    p.hadm_id,
    
    -- === CHARLSON ===
    ((rf.chf * 1) + (rf.pvd * 1) + (rf.copd * 1) + (rf.rheum * 1) + (rf.pud * 1) + 
     (rf.liver_mild * 1) + (rf.dm_uncomp * 1) + (rf.dm_comp * 2) + 
     (rf.paralysis * 2) + (rf.renal * 2) + (rf.solid_tumor * 2) + 
     (rf.liver_sev * 3) + (rf.hiv * 6) + (rf.metastatic * 6)) as charlson_comorbidity_index,
    
    -- === ELIXHAUSER ===
    ((rf.chf * 7) + (rf.arrhythmias * 5) + (rf.valvular * -1) + (rf.pulm_circ * 4) + 
     (rf.pvd * 2) + (rf.htn_comp * 0) + (rf.paralysis * 7) + (rf.neuro * 6) + 
     (rf.copd * 3) + (rf.dm_uncomp * 0) + (rf.dm_comp * 0) + (rf.thyroid * 0) + 
     (rf.renal * 5) + (rf.liver_sev * 11) + (rf.pud * 0) + (rf.hiv * 0) + 
     (rf.lymphoma * 9) + (rf.metastatic * 12) + (rf.solid_tumor * 7) + 
     (rf.rheum * 4) + (rf.coag * 3) + (rf.obesity * -4) + (rf.weight_loss * 6) + 
     (rf.electrolytes * 5) + (rf.anemia_def * -2) + (rf.alcohol * 0) + 
     (rf.drugs * -7) + (rf.psychoses * 0) + (rf.depression * -3)) as elixhauser_vanwalraven_score,

    -- Individual Flags (Explicitly named)
    rf.chf, rf.arrhythmias, rf.valvular, rf.pulm_circ, rf.pvd, rf.htn_uncomp, 
    rf.htn_comp, rf.paralysis, rf.neuro, rf.copd, rf.dm_uncomp, rf.dm_comp, 
    rf.thyroid, rf.renal, rf.liver_mild, rf.liver_sev, rf.pud, rf.hiv, 
    rf.lymphoma, rf.metastatic, rf.solid_tumor, rf.rheum, rf.coag, 
    rf.obesity, rf.weight_loss, rf.electrolytes, rf.anemia_def, 
    rf.alcohol, rf.drugs, rf.psychoses, rf.depression

FROM Patients p
LEFT JOIN raw_flags rf ON p.hadm_id = rf.hadm_id
ORDER BY p.subject_id;
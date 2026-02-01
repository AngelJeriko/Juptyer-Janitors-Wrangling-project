-- ------------------------------------------------------------------
-- TITLE: MASTER_VASCULAR_CPT_LIST (CORRECTED)
-- DESCRIPTION: Lists all CPT codes in the Vascular Surgery range (34000-37799)
-- ------------------------------------------------------------------

SELECT 
    hcpcs_cd as cpt_code,
    short_description,
    count(*) as total_count
FROM mimiciv_hosp.hcpcsevents
WHERE 
    -- 1. Standard Vascular Range (Arteries/Veins)
    -- Use Regex to ensure we only cast numbers to integers
    (hcpcs_cd ~ '^[0-9]+$' AND hcpcs_cd::integer BETWEEN 34000 AND 37799)
    
    OR
    
    -- 2. Endovascular Revascularization (Lower Extremity Stents/Angioplasty)
    (hcpcs_cd ~ '^[0-9]+$' AND hcpcs_cd::integer BETWEEN 37220 AND 37239)
    
GROUP BY hcpcs_cd, short_description
ORDER BY hcpcs_cd::integer ASC;
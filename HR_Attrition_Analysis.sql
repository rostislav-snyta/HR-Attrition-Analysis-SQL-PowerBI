-------------------------------------------------------------------------------
-- SECTION 1: DATA DEFINITION (DDL)
-- Defining the relational schema with primary keys, foreign keys, and raw staging.
-------------------------------------------------------------------------------

-- Dimensional table for office locations
CREATE TABLE t_offices (
    office_code VARCHAR(10) PRIMARY KEY,
    city VARCHAR(50) NOT NULL,
    province VARCHAR(50),
    country VARCHAR(50) NOT NULL
);

-- Dimensional table for job hierarchy
CREATE TABLE t_job_position (
    department VARCHAR(50) NOT NULL,
    job_level VARCHAR(10) NOT NULL,
    job_role VARCHAR(50) NOT NULL,
    PRIMARY KEY (department, job_level)
);

-- Fact table for external survey ratings (Longitudinal data)
CREATE TABLE t_survey (
    emp_id INT NOT NULL,
    off_cde VARCHAR(10) REFERENCES t_offices(office_code),
    rated_year INT NOT NULL,
    rating NUMERIC(5, 2) NOT NULL,
    PRIMARY KEY (emp_id, rated_year)
);

-- Staging table for raw employee data (imported from CSV)
CREATE TABLE t_employees_raw (
    employee_id INT PRIMARY KEY,
    joining_year VARCHAR(10),
    age VARCHAR(10),
    business_travel VARCHAR(20),
    daily_rate VARCHAR(10),
    department VARCHAR(50) NOT NULL,
    distance_from_home VARCHAR(10),
    education_field VARCHAR(50),
    employee_count VARCHAR(10),
    employee_number VARCHAR(10),
    environment_satisfaction VARCHAR(10),
    gender VARCHAR(10),
    hourly_rate VARCHAR(10),
    job_involvement VARCHAR(10),
    job_satisfaction VARCHAR(10),
    marital_status VARCHAR(20),
    monthly_income VARCHAR(10),
    monthly_rate VARCHAR(10),
    num_companies_worked VARCHAR(10),
    over_18 VARCHAR(5),
    over_time VARCHAR(5),
    percent_salary_hike VARCHAR(10),
    performance_rating VARCHAR(10),
    relationship_satisfaction VARCHAR(10),
    standard_hours VARCHAR(10),
    stock_option_level VARCHAR(10),
    total_working_years VARCHAR(10),
    training_times_last_year VARCHAR(10),
    work_life_balance VARCHAR(10),
    years_at_company VARCHAR(10),
    years_in_current_role VARCHAR(10),
    years_since_last_promotion VARCHAR(10),
    years_with_curr_manager VARCHAR(10),
    attrition VARCHAR(5),
    leaving_year VARCHAR(10),
    reason VARCHAR(50),
    relieving_status VARCHAR(50),
    office_code VARCHAR(10) REFERENCES t_offices(office_code),
    job_level_updated VARCHAR(10) NOT NULL
);

-------------------------------------------------------------------------------
-- SECTION 2: ANALYTCAL VIEW (DATA TRANSFORMATION)
-- Creating a central view that handles type casting, NULL handling, and joins.
-- This layer maintains a granularity of 1 row per survey year (~47k rows).
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_analytics_data AS
SELECT 
    T1.employee_id,
    T1.department,
    T3.job_role,
    T4.country AS office_country,
    T1.gender,
    T1.marital_status,
    T1.business_travel,
    CAST(NULLIF(T1.age, '') AS INT) AS age,
    CAST(NULLIF(T1.monthly_income, '') AS INT) AS monthly_income,
    CAST(NULLIF(T1.total_working_years, '') AS INT) AS total_working_years,
    CAST(NULLIF(T1.years_at_company, '') AS INT) AS years_at_company,
    CAST(NULLIF(T1.years_with_curr_manager, '') AS INT) AS years_with_curr_manager,
    T1.over_time,
    CAST(REPLACE(T1.job_level_updated, 'L', '') AS INT) AS job_level_num,
    T2.rated_year AS survey_year,
    T2.rating AS survey_external_rating,
    CAST(NULLIF(T1.job_satisfaction, '') AS INT) AS satisfaction_score,
    CAST(NULLIF(T1.work_life_balance, '') AS INT) AS work_life_balance,
    T1.attrition
FROM t_employees_raw T1
LEFT JOIN t_survey T2 ON T1.employee_id = T2.emp_id
LEFT JOIN t_job_position T3 ON T1.department = T3.department AND T1.job_level_updated = T3.job_level
LEFT JOIN t_offices T4 ON T1.office_code = T4.office_code;

-------------------------------------------------------------------------------
-- SECTION 3: BUSINESS VALIDATIONS & KPI ANALYSIS
-- Using DISTINCT ON to deduplicate historical records and focus on the 
-- employee's state at the moment of departure (or latest available year).
-------------------------------------------------------------------------------

-- 1. Overtime Impact (The Primary Churn Driver)
-- Captures the massive 64.29% attrition rate among employees working overtime.
SELECT 
    over_time,
    COUNT(*) as unique_employees,
    ROUND(AVG(CASE WHEN attrition = 'Yes' THEN 1 ELSE 0 END) * 100, 2) as attrition_rate_pct
FROM (
    SELECT DISTINCT ON (employee_id) * FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as unique_staff
GROUP BY over_time;

-- 2. Income Bracket Validation
-- Analyzing churn risk across income levels; highlights high attrition even in well-paid groups.
SELECT 
    income_bracket,
    COUNT(*) as employees,
    ROUND(AVG(CASE WHEN attrition = 'Yes' THEN 1 ELSE 0 END) * 100, 2) as attrition_rate_pct
FROM (
    SELECT DISTINCT ON (employee_id) 
        CASE 
            WHEN monthly_income < 3000 THEN 'Low (<3k)'
            WHEN monthly_income BETWEEN 3000 AND 7000 THEN 'Medium (3k-7k)'
            WHEN monthly_income BETWEEN 7000 AND 12000 THEN 'High (7k-12k)'
            ELSE 'Executive (12k+)'
        END as income_bracket,
        attrition,
        employee_id
    FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as latest_data
GROUP BY income_bracket
ORDER BY attrition_rate_pct DESC;

-- 3. Manager Stability Analysis
-- Validates the "People leave managers, not companies" hypothesis.
SELECT 
    manager_tenure,
    COUNT(*) as employees,
    ROUND(AVG(CASE WHEN attrition = 'Yes' THEN 1 ELSE 0 END) * 100, 2) as attrition_rate_pct
FROM (
    SELECT DISTINCT ON (employee_id) 
        CASE 
            WHEN years_with_curr_manager <= 2 THEN 'New Manager (0-2y)'
            WHEN years_with_curr_manager <= 5 THEN 'Stable Manager (3-5y)'
            ELSE 'Long-term Manager (5y+)'
        END as manager_tenure,
        attrition,
        employee_id
    FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as latest_manager
GROUP BY manager_tenure
ORDER BY attrition_rate_pct DESC;

-- 4. Final Year Mood (Predictive Indicators)
-- Comparing average satisfaction scores of leavers vs. stayers in their final recorded year.
SELECT 
    attrition,
    ROUND(AVG(survey_external_rating), 2) as avg_satisfaction_final_year,
    ROUND(AVG(work_life_balance), 2) as avg_wlb_final_year
FROM (
    SELECT DISTINCT ON (employee_id) 
        survey_external_rating,
        work_life_balance,
        attrition,
        employee_id
    FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as final_mood
GROUP BY attrition;

-- 5. Longitudinal Trend (Real Annual Attrition)
-- We use DISTINCT ON to identify the exact year an employee left.
-- This prevents duplicating leavers across their entire tenure.
SELECT 
    survey_year,
    COUNT(*) as real_exits_in_this_year,
    ROUND(AVG(survey_external_rating), 2) as avg_happiness_of_leavers
FROM (
    SELECT DISTINCT ON (employee_id) 
        survey_year, attrition, survey_external_rating
    FROM v_analytics_data
    WHERE attrition = 'Yes' 
    ORDER BY employee_id, survey_year DESC
) as final_exit_records
GROUP BY survey_year
ORDER BY survey_year;

-- 6. Business Travel Correlation
-- Identifies mobility as a major churn risk factor.
SELECT 
    business_travel,
    COUNT(*) as employees,
    ROUND(AVG(CASE WHEN attrition = 'Yes' THEN 1 ELSE 0 END) * 100, 2) as attrition_rate_pct
FROM (
    SELECT DISTINCT ON (employee_id) business_travel, attrition, employee_id
    FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as latest
GROUP BY 1 ORDER BY 3 DESC;

-- 7. Marital Status Flexibility
-- Demographical analysis of employee stability.
SELECT 
    marital_status,
    COUNT(*) as employees,
    ROUND(AVG(CASE WHEN attrition = 'Yes' THEN 1 ELSE 0 END) * 100, 2) as attrition_rate_pct
FROM (
    SELECT DISTINCT ON (employee_id) marital_status, attrition, employee_id
    FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as latest
GROUP BY 1 ORDER BY 3 DESC;

-- 8. Job Satisfaction (Internal Mood Validation)
-- Cross-validating survey responses with actual attrition events.
SELECT 
    satisfaction_score,
    COUNT(*) as employees,
    ROUND(AVG(CASE WHEN attrition = 'Yes' THEN 1 ELSE 0 END) * 100, 2) as attrition_rate_pct
FROM (
    SELECT DISTINCT ON (employee_id) satisfaction_score, attrition, employee_id
    FROM v_analytics_data 
    ORDER BY employee_id, survey_year DESC
) as latest
GROUP BY 1 ORDER BY 1 DESC;

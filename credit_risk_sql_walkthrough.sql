-- Query 1: See what the data looks like
-- Highlight just this query and press F5
SELECT
    sk_id_curr,
    amt_credit          AS loan_amount,
    amt_income_total    AS annual_income,
    target              AS defaulted
FROM stg_application
LIMIT 10;



WITH bureau_summary AS (
    SELECT
        sk_id_curr,
        COUNT(*)                                                AS num_bureau_credits,
        SUM(CASE WHEN credit_active = 'Active' THEN 1 ELSE 0 END)
                                                                AS num_active_credits,
        ROUND(AVG(credit_day_overdue)::numeric, 1)              AS avg_days_overdue
    FROM stg_bureau
    GROUP BY sk_id_curr
),
prev_loans AS (
    SELECT
        sk_id_curr,
        COUNT(DISTINCT sk_id_prev)                              AS num_prev_loans,
        SUM(CASE WHEN name_contract_status = 'Refused' THEN 1 ELSE 0 END)
                                                                AS num_refused_loans,
        ROUND(AVG(amt_credit)::numeric, 0)                      AS avg_prev_loan_amount
    FROM stg_previous_application
    GROUP BY sk_id_curr
)
SELECT
    a.sk_id_curr,
    a.target                                        AS defaulted,
    ABS(a.days_birth) / 365                         AS age_years,
    a.amt_income_total                              AS annual_income,
    a.amt_credit                                    AS loan_amount,
    ROUND((a.amt_credit /
        NULLIF(a.amt_income_total, 0))::numeric, 2) AS debt_to_income_ratio,
    a.name_income_type,
    a.name_education_type,
    COALESCE(b.num_bureau_credits, 0)               AS num_bureau_credits,
    COALESCE(b.num_active_credits, 0)               AS num_active_credits,
    COALESCE(b.avg_days_overdue, 0)                 AS avg_days_overdue,
    COALESCE(p.num_prev_loans, 0)                   AS num_prev_loans,
    COALESCE(p.num_refused_loans, 0)                AS num_refused_loans,
    COALESCE(p.avg_prev_loan_amount, 0)             AS avg_prev_loan_amount
FROM stg_application a
LEFT JOIN bureau_summary b  ON a.sk_id_curr = b.sk_id_curr
LEFT JOIN prev_loans p      ON a.sk_id_curr = p.sk_id_curr
LIMIT 50;


-- Step 1 only: calculate PD per income segment
WITH segment_pd AS (
    SELECT
        name_income_type                        AS income_segment,
        COUNT(*)                                AS total_customers,
        SUM(target)                             AS total_defaults,
        ROUND(AVG(target)::numeric, 4)          AS pd
    FROM stg_application
    GROUP BY name_income_type
    HAVING COUNT(*) > 500
)
SELECT *
FROM segment_pd
ORDER BY pd DESC;


-- Step 1: PD per segment
WITH segment_pd AS (
    SELECT
        name_income_type                        AS income_segment,
        COUNT(*)                                AS total_customers,
        ROUND(AVG(target)::numeric, 4)          AS pd
    FROM stg_application
    GROUP BY name_income_type
    HAVING COUNT(*) > 500
),
-- Step 2: Average loan exposure per segment (EAD)
segment_ead AS (
    SELECT
        name_income_type                        AS income_segment,
        ROUND(AVG(amt_credit)::numeric, 0)      AS avg_exposure
    FROM stg_application
    GROUP BY name_income_type
)
-- Join both steps together
SELECT
    pd.income_segment,
    pd.total_customers,
    pd.pd                                       AS probability_of_default,
    ead.avg_exposure                            AS exposure_at_default
FROM segment_pd pd
JOIN segment_ead ead
    ON pd.income_segment = ead.income_segment
ORDER BY pd.pd DESC;



WITH segment_pd AS (
    SELECT
        name_income_type                                AS income_segment,
        COUNT(*)                                        AS total_customers,
        ROUND(AVG(target)::numeric, 4)                  AS pd
    FROM stg_application
    GROUP BY name_income_type
    HAVING COUNT(*) > 500
),
segment_ead AS (
    SELECT
        name_income_type                                AS income_segment,
        ROUND(AVG(amt_credit)::numeric, 0)              AS avg_exposure
    FROM stg_application
    GROUP BY name_income_type
),
-- Step 3: calculate Expected Loss
-- LGD is fixed at 0.45 (45%)
expected_loss AS (
    SELECT
        pd.income_segment,
        pd.total_customers,
        pd.pd                                           AS probability_of_default,
        ead.avg_exposure                                AS exposure_at_default,
        0.45                                            AS loss_given_default,
        ROUND((pd.pd * 0.45 * ead.avg_exposure)::numeric, 0)
                                                        AS expected_loss_per_customer
    FROM segment_pd pd
    JOIN segment_ead ead
        ON pd.income_segment = ead.income_segment
)
SELECT
    income_segment,
    total_customers,
    ROUND((probability_of_default * 100)::numeric, 2)   AS pd_pct,
    exposure_at_default,
    expected_loss_per_customer,
    ROUND((expected_loss_per_customer * total_customers)::numeric, 0)
                                                        AS total_segment_expected_loss
FROM expected_loss
ORDER BY total_segment_expected_loss DESC;







CREATE OR REPLACE VIEW risk_summary AS

WITH bureau_agg AS (
    SELECT
        sk_id_curr,
        COUNT(*)                                            AS num_bureau_credits,
        SUM(CASE WHEN credit_active = 'Active' THEN 1 ELSE 0 END)
                                                            AS active_credits,
        ROUND(AVG(credit_day_overdue)::numeric, 1)          AS avg_days_overdue,
        ROUND(SUM(amt_credit_sum)::numeric, 0)              AS total_bureau_exposure,
        ROUND(SUM(amt_credit_sum_overdue)::numeric, 0)      AS total_overdue_amt
    FROM stg_bureau
    GROUP BY sk_id_curr
),
prev_agg AS (
    SELECT
        sk_id_curr,
        COUNT(DISTINCT sk_id_prev)                          AS num_prev_applications,
        SUM(CASE WHEN name_contract_status = 'Refused' THEN 1 ELSE 0 END)
                                                            AS num_refusals,
        ROUND(AVG(amt_credit)::numeric, 0)                  AS avg_prev_credit
    FROM stg_previous_application
    GROUP BY sk_id_curr
),
payment_agg AS (
    SELECT
        sk_id_curr,
        COUNT(*)                                            AS total_installments,
        SUM(CASE WHEN days_entry_payment > days_instalment
            THEN 1 ELSE 0 END)                             AS late_payments,
        ROUND(AVG(amt_payment)::numeric, 0)                 AS avg_payment_amount
    FROM stg_installments_payments
    WHERE days_instalment IS NOT NULL
      AND days_entry_payment IS NOT NULL
    GROUP BY sk_id_curr
)

SELECT
    a.sk_id_curr                                            AS customer_id,
    a.target                                                AS defaulted,
    ABS(a.days_birth) / 365                                 AS age_years,
    a.code_gender                                           AS gender,
    a.name_education_type                                   AS education,
    a.name_income_type                                      AS income_type,
    a.name_family_status                                    AS family_status,
    a.cnt_children                                          AS num_children,
    CASE
        WHEN a.days_employed = 365243 THEN 0
        ELSE ABS(a.days_employed) / 365
    END                                                     AS years_employed,
    a.name_contract_type                                    AS loan_type,
    ROUND(a.amt_credit::numeric, 0)                         AS loan_amount,
    ROUND(a.amt_income_total::numeric, 0)                   AS annual_income,
    ROUND(a.amt_annuity::numeric, 0)                        AS monthly_annuity,
    ROUND((a.amt_credit /
        NULLIF(a.amt_income_total, 0))::numeric, 2)         AS debt_to_income_ratio,
    COALESCE(b.num_bureau_credits, 0)                       AS num_bureau_credits,
    COALESCE(b.active_credits, 0)                           AS active_credits,
    COALESCE(b.avg_days_overdue, 0)                         AS avg_days_overdue,
    COALESCE(b.total_bureau_exposure, 0)                    AS total_bureau_exposure,
    COALESCE(p.num_prev_applications, 0)                    AS num_prev_applications,
    COALESCE(p.num_refusals, 0)                             AS num_refusals,
    COALESCE(py.total_installments, 0)                      AS total_installments,
    COALESCE(py.late_payments, 0)                           AS late_payments,
    ROUND(
        COALESCE(py.late_payments, 0) * 100.0 /
        NULLIF(COALESCE(py.total_installments, 0), 0)
    )                                                       AS late_payment_rate_pct,
    CASE
        WHEN ABS(a.days_birth) / 365 < 30 THEN 'Under 30'
        WHEN ABS(a.days_birth) / 365 < 45 THEN '30-44'
        WHEN ABS(a.days_birth) / 365 < 60 THEN '45-59'
        ELSE '60+'
    END                                                     AS age_group,
    CASE
        WHEN COALESCE(b.avg_days_overdue, 0) > 30
          OR ROUND((a.amt_credit /
            NULLIF(a.amt_income_total, 0))::numeric, 2) > 5
          OR COALESCE(p.num_refusals, 0) > 2
          OR COALESCE(py.late_payments, 0) > 5
        THEN 'High Risk'
        WHEN COALESCE(b.avg_days_overdue, 0) > 5
          OR ROUND((a.amt_credit /
            NULLIF(a.amt_income_total, 0))::numeric, 2) > 3
          OR COALESCE(p.num_refusals, 0) > 0
          OR COALESCE(py.late_payments, 0) > 2
        THEN 'Medium Risk'
        ELSE 'Low Risk'
    END                                                     AS risk_tier,
    ROUND((
        COALESCE(py.late_payments, 0) * 1.0 /
        NULLIF(COALESCE(py.total_installments, 0), 0)
        * 0.45
        * a.amt_credit
    )::numeric, 0)                                          AS expected_loss

FROM stg_application a
LEFT JOIN bureau_agg  b  ON a.sk_id_curr = b.sk_id_curr
LEFT JOIN prev_agg    p  ON a.sk_id_curr = p.sk_id_curr
LEFT JOIN payment_agg py ON a.sk_id_curr = py.sk_id_curr;


SELECT * FROM risk_summary;



CREATE OR REPLACE VIEW payment_trend AS
SELECT
    ROUND(ABS(days_instalment) / 30)::int         AS month_bucket,
    COUNT(*)                                        AS total_payments,
    SUM(CASE WHEN days_entry_payment > days_instalment
        THEN 1 ELSE 0 END)                          AS late_payments,
    ROUND(
        SUM(CASE WHEN days_entry_payment > days_instalment
            THEN 1 ELSE 0 END) * 100.0 /
        NULLIF(COUNT(*), 0)
    , 2)                                            AS late_rate_pct
FROM stg_installments_payments
WHERE days_instalment IS NOT NULL
  AND days_entry_payment IS NOT NULL
  AND ABS(days_instalment) / 30 BETWEEN 1 AND 60
GROUP BY ROUND(ABS(days_instalment) / 30)::int
ORDER BY month_bucket;
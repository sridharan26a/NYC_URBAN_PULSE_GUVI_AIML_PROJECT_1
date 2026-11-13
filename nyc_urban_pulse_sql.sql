select * from service_request

-- 1. Total distinct request volume
SELECT COUNT(DISTINCT unique_key) AS total_distinct_requests
FROM service_request;

-- 2. Top 10 complaint categories by count
SELECT complaint_type,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
GROUP BY complaint_type
ORDER BY requests DESC
LIMIT 10;

-- 3. Agency workload distribution
SELECT agency,
       agency_name,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
GROUP BY agency, agency_name
ORDER BY requests DESC;

-- 4. Request volume by borough
SELECT borough,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
GROUP BY borough
ORDER BY requests DESC;

-- 5. Monthly request trend (the data covers only part of each month, see the daily view below)
SELECT month,
       COUNT(*) AS requests,
       MIN(created_day) AS first_day_in_data,
       MAX(created_day) AS last_day_in_data,
       COUNT(DISTINCT created_day) AS days_covered,
       ROUND(1.0 * COUNT(*) / COUNT(DISTINCT created_day), 0) AS avg_requests_per_day
FROM service_request
GROUP BY month
ORDER BY MIN(created_day);

-- 5b. Daily trend (fairer than the monthly totals for a short window)
SELECT created_day,
       COUNT(*) AS requests
FROM service_request
GROUP BY created_day
ORDER BY created_day;

-- 6a. Demand by weekday
SELECT day_of_week,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
GROUP BY day_of_week
ORDER BY CASE day_of_week
           WHEN 'Monday' THEN 1 WHEN 'Tuesday' THEN 2 WHEN 'Wednesday' THEN 3
           WHEN 'Thursday' THEN 4 WHEN 'Friday' THEN 5 WHEN 'Saturday' THEN 6
           WHEN 'Sunday' THEN 7 END;

-- 6b. Demand by hour of day
SELECT hour,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
GROUP BY hour
ORDER BY hour;

-- 6c. Weekday x hour grid (use for a heatmap)
SELECT day_of_week,
       hour,
       COUNT(*) AS requests
FROM service_request
GROUP BY day_of_week, hour
ORDER BY CASE day_of_week
           WHEN 'Monday' THEN 1 WHEN 'Tuesday' THEN 2 WHEN 'Wednesday' THEN 3
           WHEN 'Thursday' THEN 4 WHEN 'Friday' THEN 5 WHEN 'Saturday' THEN 6
           WHEN 'Sunday' THEN 7 END,
         hour;
-- NYC 311 Urban Pulse: status, resolution time, geography and closure analysis (PostgreSQL)
-- Table: nyc_311_requests (see nyc311_postgres.sql)
--
-- Definition of a "valid resolution duration":
--   * the request is closed (is_closed), AND
--   * resolution_action_updated_date is not earlier than created_date.
-- The resolution_hours column in the table is NOT used, because the cleaning step set negative
-- gaps to 0 and filled missing update dates with created_date. Durations are recomputed here.

CREATE OR REPLACE VIEW valid_resolutions AS
SELECT unique_key, agency, agency_name, complaint_type, borough,
       created_date, resolution_action_updated_date,
       EXTRACT(EPOCH FROM (resolution_action_updated_date - created_date)) / 3600.0 AS res_hours
FROM service_request
WHERE is_closed
  AND resolution_action_updated_date >= created_date;

-- IQR fences for the valid durations (reused by section 5)
CREATE OR REPLACE VIEW res_fences AS
SELECT q1, q3, q3 - q1 AS iqr,
       q1 - 1.5 * (q3 - q1) AS lower_fence,
       q3 + 1.5 * (q3 - q1) AS upper_fence
FROM (SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY res_hours) AS q1,
             PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY res_hours) AS q3
      FROM valid_resolutions) t;

-- Borough median point, used to spot coordinates that were filled in during cleaning
CREATE OR REPLACE VIEW borough_median_point AS
SELECT borough,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY latitude)  AS med_lat,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY longitude) AS med_lon
FROM service_request
GROUP BY borough;

CREATE OR REPLACE VIEW usable_coordinates AS
SELECT r.*
FROM service_request r
JOIN borough_median_point m ON m.borough = r.borough
WHERE NOT (r.latitude = m.med_lat AND r.longitude = m.med_lon);


-- 7. Distribution of recorded request statuses
SELECT status,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
GROUP BY status
ORDER BY requests DESC;


-- 8. Descriptive statistics for valid resolution durations (hours)
SELECT COUNT(*) AS valid_closed_requests,
       ROUND(AVG(res_hours)::numeric, 2)         AS mean_h,
       ROUND(STDDEV_SAMP(res_hours)::numeric, 2) AS std_h,
       ROUND(MIN(res_hours)::numeric, 2)         AS min_h,
       ROUND((PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p05_h,
       ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p25_h,
       ROUND((PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS median_h,
       ROUND((PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p75_h,
       ROUND((PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p90_h,
       ROUND((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p95_h,
       ROUND((PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p99_h,
       ROUND(MAX(res_hours)::numeric, 2)         AS max_h
FROM valid_resolutions;


-- 9. Median resolution duration by complaint category (at least 200 valid closed requests)
SELECT complaint_type,
       COUNT(*) AS valid_closed,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS median_hours
FROM valid_resolutions
GROUP BY complaint_type
HAVING COUNT(*) >= 200
ORDER BY median_hours DESC;


-- 10. Median resolution duration by agency
SELECT agency,
       COUNT(*) AS valid_closed,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS median_hours,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY res_hours))::numeric, 2) AS p90_hours
FROM valid_resolutions
GROUP BY agency
ORDER BY median_hours DESC;


-- 11a. IQR outlier summary
SELECT ROUND(f.q1::numeric, 2)          AS q1_h,
       ROUND(f.q3::numeric, 2)          AS q3_h,
       ROUND(f.iqr::numeric, 2)         AS iqr_h,
       ROUND(f.lower_fence::numeric, 2) AS lower_fence_h,
       ROUND(f.upper_fence::numeric, 2) AS upper_fence_h,
       COUNT(*) AS valid_closed,
       COUNT(*) FILTER (WHERE v.res_hours > f.upper_fence) AS high_outliers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE v.res_hours > f.upper_fence) / COUNT(*), 2) AS high_outlier_pct
FROM valid_resolutions v
CROSS JOIN res_fences f
GROUP BY f.q1, f.q3, f.iqr, f.lower_fence, f.upper_fence;

-- 11b. Where the outliers come from: by agency
SELECT v.agency,
       COUNT(*) AS valid_closed,
       COUNT(*) FILTER (WHERE v.res_hours > f.upper_fence) AS outliers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE v.res_hours > f.upper_fence) / COUNT(*), 1) AS outlier_pct
FROM valid_resolutions v
CROSS JOIN res_fences f
GROUP BY v.agency
ORDER BY outliers DESC;

-- 11c. Where the outliers come from: top 10 complaint types by outlier count
SELECT v.complaint_type,
       COUNT(*) AS valid_closed,
       COUNT(*) FILTER (WHERE v.res_hours > f.upper_fence) AS outliers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE v.res_hours > f.upper_fence) / COUNT(*), 1) AS outlier_pct
FROM valid_resolutions v
CROSS JOIN res_fences f
GROUP BY v.complaint_type
ORDER BY outliers DESC
LIMIT 10;


-- 12a. Skewness of resolution time (population skewness, same as scipy.stats.skew)
WITH s AS (
    SELECT AVG(res_hours) AS mean_h, STDDEV_POP(res_hours) AS sd_h
    FROM valid_resolutions
)
SELECT ROUND(s.mean_h::numeric, 2) AS mean_h,
       ROUND((AVG(POWER(v.res_hours - s.mean_h, 3)) / POWER(s.sd_h, 3))::numeric, 3) AS skewness
FROM valid_resolutions v
CROSS JOIN s
GROUP BY s.mean_h, s.sd_h;

-- 12b. Distribution of resolution time in buckets
SELECT CASE WHEN res_hours <= 1  THEN '1) up to 1 hour'
            WHEN res_hours <= 6  THEN '2) 1 to 6 hours'
            WHEN res_hours <= 24 THEN '3) 6 to 24 hours'
            WHEN res_hours <= 72 THEN '4) 1 to 3 days'
            ELSE                      '5) over 3 days' END AS duration_bucket,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM valid_resolutions
GROUP BY 1
ORDER BY 1;


-- 13a. Borough summary and how many rows have usable (not filled-in) coordinates
SELECT r.borough,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
       COUNT(u.unique_key) AS usable_coordinates,
       ROUND(100.0 * COUNT(u.unique_key) / COUNT(*), 1) AS usable_pct
FROM service_request r
LEFT JOIN usable_coordinates u ON u.unique_key = r.unique_key
GROUP BY r.borough
ORDER BY requests DESC;

-- 13b. Top 10 zip codes
SELECT incident_zip,
       MIN(borough) AS borough,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM service_request
WHERE incident_zip IS NOT NULL
GROUP BY incident_zip
ORDER BY requests DESC
LIMIT 10;

-- 13c. Hotspots on a roughly 1 km grid (coordinates rounded to 2 decimals), usable coordinates only
SELECT ROUND(latitude::numeric, 2)  AS grid_lat,
       ROUND(longitude::numeric, 2) AS grid_lon,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_usable
FROM usable_coordinates
GROUP BY 1, 2
ORDER BY requests DESC
LIMIT 10;


-- 14a. Recorded closure rate overall
SELECT COUNT(*) AS requests,
       COUNT(*) FILTER (WHERE is_closed) AS closed,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_closed) / COUNT(*), 1) AS closure_rate_pct
FROM service_request;

-- 14b. Closure rate by borough
SELECT borough,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_closed) / COUNT(*), 1) AS closure_rate_pct
FROM service_request
GROUP BY borough
ORDER BY closure_rate_pct;

-- 14c. Closure rate by agency
SELECT agency,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_closed) / COUNT(*), 1) AS closure_rate_pct
FROM service_request
GROUP BY agency
ORDER BY closure_rate_pct;

-- 14d. Lowest closure rates by complaint type (at least 200 requests)
SELECT complaint_type,
       COUNT(*) AS requests,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_closed) / COUNT(*), 1) AS closure_rate_pct
FROM service_request
GROUP BY complaint_type
HAVING COUNT(*) >= 200
ORDER BY closure_rate_pct
LIMIT 10;


-- 15. High request volume AND long median resolution duration
--    Change min_requests / long_hours in the params CTE to tighten or loosen the rule.
WITH volume AS (
    SELECT complaint_type,
           COUNT(*) AS requests,
           ROUND(100.0 * COUNT(*) FILTER (WHERE is_closed) / COUNT(*), 1) AS closure_rate_pct
    FROM service_request
    GROUP BY complaint_type
),
duration AS (
    SELECT complaint_type,
           COUNT(*) AS valid_closed,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY res_hours) AS median_hours
    FROM valid_resolutions
    GROUP BY complaint_type
    HAVING COUNT(*) >= 100
),
params AS (
    SELECT 1000 AS min_requests, 24 AS long_hours
)
SELECT v.complaint_type,
       v.requests,
       d.valid_closed,
       ROUND(d.median_hours::numeric, 1) AS median_hours,
       v.closure_rate_pct
FROM volume v
JOIN duration d USING (complaint_type)
CROSS JOIN params p
WHERE v.requests >= p.min_requests
  AND d.median_hours >= p.long_hours
ORDER BY v.requests DESC;

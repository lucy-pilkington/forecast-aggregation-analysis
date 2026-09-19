# =============================================================================
# Forecast aggregation analysis: RCT-A tournament data
#
# Compares five standard methods for aggregating individual forecasts into a
# group prediction, then tests whether weighting forecasters by historical
# accuracy improves on the best of them.
#
# Data: the RCT-A files from the Hybrid Forecasting Competition Dataverse
# (rct-a-questions-answers.tab, rct-a-daily-forecasts.csv).
#
# To run: set data_path below to the folder holding the raw files.
# =============================================================================
# 1. Set Working Directory
data_path <- "/path/to/your/data/folder"
setwd(data_path)

# 2. Load libraries (install via install.packages() if needed)
# install.packages("data.table")
# install.packages("tidyverse")
# install.packages("forecast")
library(data.table) # Preferred for large datasets and robust parsing
library(tidyverse)  # For data manipulation
library(lubridate)  # We use the lubridate package (part of tidyverse) to handle the full timestamps.
library(forecast)   # We use the forecast package to run the Diebold-Mariano test.

# =============================================================================
# SECTION 1: DATA IMPORT
# Purpose: Load raw HFC forecasting data and handle structural inconsistencies.

# Note: Using tab-delimiter for the questions file to preserve text formatting and prevent errors from 
# commas within the question strings. 
# =============================================================================
# Create function to standardise colnames to underscores for all files
clean_column_names <- function(df) {
  names(df) <- gsub("\\.| ", "_", tolower(names(df)))
  return(df)
}

# 1. Load Questions-Answers File
# Note: This is a .tab file. We use fill=TRUE because some rows (e.g. row 245) 
# have extra delimiters caused by complex text in the 'question description' field.
questions <- fread("rct-a-questions-answers.tab", sep = "\t", fill = TRUE, header = TRUE)
questions <- clean_column_names(questions)

# Standardise the resolution column
# We use 'resolution' as a shorthand for the ground-truth outcome (1 = Happened, 0 = Did not)
questions <- questions %>%
  mutate(resolution = as.numeric(get("answer_resolved_probability"))) 

# 2. Load forecast file
# Note: fread is significantly faster than read.csv for files >500MB.
# Note: rct-a-prediction-sets.csv (the raw update log) is not loaded here.
# The daily file already represents the standing forecast per participant per day,
# which is equivalent to deriving it from prediction-sets but far more memory-efficient.
daily <- clean_column_names(fread("rct-a-daily-forecasts.csv"))

# Quick Validation
cat("Questions loaded:", nrow(questions), "\n")

# =============================================================================
# SECTION 2: DATA CLEANING & PRE-PROCESSING
# Purpose: Clean, filter, and standardise the raw daily forecast data while 
# managing severe memory constraints (16GB RAM limit).

# Note: This section utilises a chunked iterative strategy with the 
# data.table engine. By processing the 1GB+ dataset in batches of 50 questions, 
# we prevent the many-to-many bloom (relational expansion) from exceeding 
# physical RAM. We use in-place modification and explicit column 
# projection to avoid memory-intensive data duplication and naming clashes.
# =============================================================================

# 1. Prepare Metadata
setDT(questions)
setDT(daily)

# Standardise names before starting the loop to avoid missing column errors
valid_ids <- questions[!is.na(resolution), unique(discover_question_id)]

# 2. Define the chunking loop
chunk_size <- 50
id_chunks <- split(valid_ids, ceiling(seq_along(valid_ids) / chunk_size))
daily_latest_list <- list() 

cat("Starting chunked processing...\n")

for (i in seq_along(id_chunks)) {
  current_ids <- id_chunks[[i]]
  
  # Step A: Subset 'daily' and select only essential columns.
  # We include discover_answer_id here so the join in Step C can match each
  # forecast to its specific answer option, preventing row duplication.
  temp_chunk <- daily[discover_question_id %in% current_ids,
                      .(discover_question_id, discover_answer_id, external_predictor_id, date, forecast, created_at)]

  if (nrow(temp_chunk) > 0) {
    # Step B: Standardise dates
    temp_chunk[, date_only := as_date(date)]

    # Step C: Join metadata on both keys to ensure each forecast row matches
    # exactly one answer option. This avoids the cartesian duplication that
    # would otherwise occur for questions with multiple answer options (3-5 in RCTA).
    temp_chunk <- merge(temp_chunk,
                        questions[discover_question_id %in% current_ids,
                                  .(discover_question_id,
                                    discover_answer_id,
                                    start_dt = as_date(question_starts_at),
                                    end_dt = as_date(question_ends_at),
                                    resolution)],
                        by = c("discover_question_id", "discover_answer_id"))
    
    # Step D: Apply live-window and numerical cleaning
    temp_chunk <- temp_chunk[date_only >= start_dt & date_only <= end_dt]
    temp_chunk[, forecast := as.numeric(forecast)]
    temp_chunk <- temp_chunk[!is.na(forecast)]
    
    # Step E: Apply clipping and odds calculation
    temp_chunk[, prob_clipped := pmax(pmin(forecast, 0.999), 0.001)]
    temp_chunk[, odds := prob_clipped / (1 - prob_clipped)]
    
    # Step F: Get the latest forecast per day
    setorder(temp_chunk, discover_question_id, discover_answer_id, external_predictor_id, date_only, -created_at)
    
    latest_chunk <- temp_chunk[, .SD[1], 
                               by = .(discover_question_id, discover_answer_id, external_predictor_id, date_only)]
    
    daily_latest_list[[i]] <- latest_chunk
  }
  
  cat("Processed chunk", i, "of", length(id_chunks), "\n")
  gc() 
}

# 3. Combine processed chunks back together
daily_latest <- rbindlist(daily_latest_list, fill = TRUE)

# Diagnostic: check for duplicate rows per forecaster per answer per day
dup_check <- daily_latest[, .N, 
                          by = .(discover_question_id, discover_answer_id, 
                                 external_predictor_id, date_only)]
cat("Max forecaster appearances per question-answer-day:", max(dup_check$N), "\n")
cat("Mean forecaster appearances per question-answer-day:", mean(dup_check$N), "\n")

# 4. Final cleanup
rm(daily, questions, daily_latest_list)
daily_latest[, c("start_dt", "end_dt", "date") := NULL]
gc()

cat("Data cleaning complete.\n")

# =============================================================================
# SECTION 3: AGGREGATION METHODS
# Purpose: Establishing a performance baseline by comparing five distinct 
# aggregation logic models to determine which best extracts the "signal" 
# from the RCTA crowd data.
# =============================================================================

aggregates <- daily_latest %>%
  # Aggregate by the date_only column to create the question-day pairs.
  group_by(discover_question_id, discover_answer_id, date_only) %>%
  summarise(
    # Carry the ground truth forward for scoring in Section 4
    resolution = first(resolution),
    # Method 1 & 2 & 4: Linear averages
    method_1_raw_mean = mean(forecast),
    method_2_median = median(forecast),
    method_4_trimmed_mean = mean(forecast, trim = 0.1),
    
    # Method 3: Geometric mean 
    # (Uses standard 0.1% clipping for stability)
    method_3_geometric_mean = exp(mean(log(prob_clipped))),
    
    # Method 5: Geometric mean of odds (The 'extremising' aggregate)
    # This method uses slightly narrower boundary clipping (0.01 to 0.99) 
    # than the standard geometric mean to ensure mathematical stability in the log-odds conversion. 
    # It prevents extreme outliers from disproportionately swinging the extremised aggregate while preserving the core signal.
    method_5_geom_mean_odds = {
      m5_clipped <- pmax(pmin(forecast, 0.99), 0.01)
      m5_odds <- m5_clipped / (1 - m5_clipped)
      log_odds_mean <- mean(log(m5_odds))
      exp(log_odds_mean) / (1 + exp(log_odds_mean))
    },
    # Metadata for diagnostic checking in the memo
    n_forecasters = n(),
    .groups = "drop"
  )

# =============================================================================
# SECTION 4: SCORING (BRIER SCORES)
# Purpose: To mathematically audit the performance of each aggregation method 
# by calculating the Brier score - the industry standard for measuring 
# forecasting accuracy.

# Notes:
# 1. The Brier score: Measured as the squared error between the 
#    forecast and the actual outcome. A score of 0.00 indicates perfect 
#    prediction; 1.00 indicates total error.
# =============================================================================

# 1. Prepare the comparison data and force numeric types
# This solves the "non-numeric argument" error by ensuring resolution 
# and averages are treated as numbers, not text.
scoring_results <- aggregates %>%
  filter(!is.na(resolution)) %>%
  mutate(
    across(c(resolution, 
             method_1_raw_mean, 
             method_2_median, 
             method_3_geometric_mean, 
             method_4_trimmed_mean, 
             method_5_geom_mean_odds), 
           as.numeric)
  ) %>%
  # 2. Calculate Brier Scores 
  # (Smaller is better: 0 is a perfect forecast, 1 is a total miss)
  mutate(
    score_m1 = (method_1_raw_mean - resolution)^2,
    score_m2 = (method_2_median - resolution)^2,
    score_m3 = (method_3_geometric_mean - resolution)^2,
    score_m4 = (method_4_trimmed_mean - resolution)^2,
    score_m5 = (method_5_geom_mean_odds - resolution)^2
  )

# 3. Create the Final Accuracy Table
accuracy_table <- scoring_results %>%
  summarise(
    `Raw Mean` = mean(score_m1, na.rm = TRUE),
    `Median` = mean(score_m2, na.rm = TRUE),
    `Geometric Mean` = mean(score_m3, na.rm = TRUE),
    `Trimmed Mean` = mean(score_m4, na.rm = TRUE),
    `Geom Mean of Odds` = mean(score_m5, na.rm = TRUE)
  ) %>%
  pivot_longer(cols = everything(), 
               names_to = "Method", 
               values_to = "Mean Brier Score") %>%
  arrange(`Mean Brier Score`)

# Display the baseline ranking
print(accuracy_table)

# =============================================================================
# SECTION 5: STATISTICAL SIGNIFICANCE (DIEBOLD-MARIANO TEST)
# Purpose: Determine if the performance gap between the Geometric Mean of Odds (M5)
# and the Trimmed Mean (M4) is statistically significant.

# Notes:
# 1. The Diebold-Mariano test: Compares the series of forecast errors to see if
#    one method is consistently more accurate than the other.
# 2. Caveat: DM assumes a single time series of forecast errors. Here it is
#    applied to a pooled panel of question-answer-days, whose errors are
#    correlated within questions, so the p-value is likely anti-conservative.
#    Read it as directional evidence rather than an exact significance level;
#    a block bootstrap clustered by question would be the stricter test.
# =============================================================================

# Running the test:
# dm.test expects raw forecast errors (forecast - actual), not pre-squared Brier components.
# A negative DM statistic indicates method 5 (geometric mean of odds) has lower error than method 4 (trimmed mean).
dm_validation <- dm.test(
  scoring_results$method_5_geom_mean_odds - scoring_results$resolution,
  scoring_results$method_4_trimmed_mean - scoring_results$resolution,
  h = 1, power = 2
)

# Output the results to the console
cat("\n--- Statistical Significance Test: Geom Mean of Odds vs Trimmed Mean ---\n")
print(dm_validation)

# =============================================================================
# SECTION 6: IMPROVED METHOD (SKILL-WEIGHTED GEOMETRIC MEAN OF ODDS)
# Purpose: Improve the geometric mean of odds by weighting each forecaster's
# log-odds contribution by their historical accuracy on resolved questions.
#
# The standard GMO treats all forecasters equally. In practice, forecasting
# skill varies significantly — some forecasters are systematically more
# accurate than others. By upweighting skilled forecasters and downweighting
# poor ones, we extract a sharper signal from the same crowd data.
#
# IMPORTANT CAVEAT — this estimate is in-sample. Skill weights are derived
# from each forecaster's performance on resolved questions, and the weighted
# aggregate is then scored on those same questions. The reported improvement
# should therefore be read as an upper bound, not as out-of-sample performance.
# The natural next step is to split questions by resolution date, derive
# weights only from earlier ones, and score on later ones.
#
# Forecasters with fewer than 5 resolved questions get no personalised weight,
# as their track record is too short to estimate skill reliably. They are not
# dropped from the aggregate: they contribute at the global average weight,
# which preserves crowd breadth on questions with few experienced participants.
# =============================================================================

# 1. Compute per-forecaster historical accuracy across all resolved questions.
# For each forecaster, take their most recent forecast on each resolved
# question and compute the resulting Brier score.
forecaster_skill <- daily_latest %>%
  filter(!is.na(resolution)) %>%
  group_by(external_predictor_id, discover_question_id, discover_answer_id) %>%
  arrange(desc(date_only)) %>%
  slice(1) %>%
  ungroup() %>%
  mutate(ind_brier = (as.numeric(forecast) - resolution)^2) %>%
  group_by(external_predictor_id) %>%
  summarise(
    historical_brier = mean(ind_brier, na.rm = TRUE),
    n_resolved       = n(),
    .groups = "drop"
  )

# 2. Assign regularised skill weights.
# Epsilon of 0.05 limits the maximum weight ratio to ~20:1, preventing a
# handful of near-perfect forecasters from dominating the aggregate entirely.
# Forecasters with fewer than 5 resolved questions are held out of the skill
# table and pick up the global fallback weight in the join below.
global_mean_brier    <- mean(forecaster_skill$historical_brier, na.rm = TRUE)
global_fallback_weight <- 1 / (global_mean_brier + 0.05)

forecaster_skill <- forecaster_skill %>%
  filter(n_resolved >= 5) %>%
  mutate(skill_weight = 1 / (historical_brier + 0.05))

# 3. Apply skill-weighted geometric mean of odds.
# Each forecaster's log-odds is weighted by their skill score before averaging.
# Forecasters not in the skill table receive the global average weight.
improved_aggregate <- daily_latest %>%
  left_join(forecaster_skill %>% select(external_predictor_id, skill_weight),
            by = "external_predictor_id") %>%
  mutate(skill_weight = ifelse(is.na(skill_weight), global_fallback_weight, skill_weight)) %>%
  group_by(discover_question_id, discover_answer_id, date_only) %>%
  summarise(
    resolution = first(resolution),
    improved_forecast = {
      clipped    <- pmax(pmin(as.numeric(forecast), 0.99), 0.01)
      log_odds   <- log(clipped / (1 - clipped))
      w_log_odds <- sum(skill_weight * log_odds) / sum(skill_weight)
      exp(w_log_odds) / (1 + exp(w_log_odds))
    },
    .groups = "drop"
  )

# 4. Final performance audit
# We calculate the Brier score for the improved method to compare against Section 4.
improved_scoring_result <- improved_aggregate %>%
  filter(!is.na(resolution)) %>%
  mutate(score_improved = (improved_forecast - resolution)^2)

cat("\n--- Improved Method Results ---\n")
cat("Skill-Weighted GMO Brier Score:",
    mean(improved_scoring_result$score_improved, na.rm = TRUE), "\n")

# 5. Summary table
# Combines all five benchmarks with the skill-weighted method.
final_comparison <- accuracy_table %>%
  mutate(`Mean Brier Score` = as.numeric(`Mean Brier Score`)) %>%
  add_row(Method = "Skill-Weighted Geometric Mean of Odds", 
          `Mean Brier Score` = mean(improved_scoring_result$score_improved, na.rm = TRUE)) %>%
  arrange(`Mean Brier Score`) %>%
  # Format to 4 decimal places, as the gain is small in absolute terms
  mutate(`Mean Brier Score` = sprintf("%.4f", `Mean Brier Score`))

print("--- FINAL ACCURACY RANKING ---")
print(final_comparison)

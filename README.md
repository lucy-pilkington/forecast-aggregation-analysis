# Optimising Collective Intelligence: Comparing Forecast Aggregation Methods

An analysis of the publicly available RCTA forecasting tournament dataset, comparing five standard
methods for aggregating individual forecasts into a group prediction, and testing whether weighting
forecasters by their track record improves accuracy.

**Headline result:** the geometric mean of odds was the most accurate of the five standard methods.
A skill-weighted version I built improved on it further, reducing mean Brier score from 0.1104 to
0.1098.

---

## The question

When a crowd of forecasters each give a probability for the same event, how should those
probabilities be combined into a single number? The choice matters: the same underlying forecasts
can produce materially different group predictions depending on the aggregation rule, and those
predictions are used to inform decisions.

## Data

Three linked files from the RCTA tournament, totalling over 1.4GB:

| File | Contents |
|---|---|
| `rct-a-questions-answers.tab` | Ground truth: 955 forecasting problems with event criteria, active windows and resolved outcomes |
| `rct-a-prediction-sets.csv` | Every individual forecast update, capturing how forecasters reacted to news in real time |
| `rct-a-daily-forecasts.csv` | Daily snapshot of each participant's standing forecast |

The final benchmarks use the ground truth and daily consensus files, joined on question and answer
IDs. The daily consensus gives a stable standing view of the crowd rather than a series of isolated
moments, which makes it the more representative basis for comparing aggregation rules.

## Method

**Filtering.** A live-window filter excludes administrative records captured before a question opens
or after it closes. Only resolved questions are scored, so every Brier score is grounded in a
verified outcome.

**Normalisation.** Raw timestamps are normalised to discrete calendar days, giving a consistent
daily consensus across all five methods.

**Handling zero probabilities.** Geometric calculations collapse on forecasts of 0% or 100%, so
probabilities are clipped to a 0.1%–99.9% boundary, with a more conservative 1% threshold for the
geometric mean of odds. This preserves the signal from confident forecasters without letting a
single extreme value invalidate the aggregate.

## Results: five standard methods

| Method | Mean Brier score |
|---|---|
| Geometric mean of odds | 0.1104 |
| Trimmed mean | 0.1123 |
| Raw mean | 0.1125 |
| Geometric mean | 0.1136 |
| Median | 0.1138 |

*Lower is better.*

The geometric mean of odds outperformed all the linear aggregates. It is an extremising method: it
pushes the group consensus toward 0% or 100% on the assumption that forecasters systematically
under-report their confidence. Its performance here is consistent with that assumption holding in
this dataset. The linear methods (raw mean, trimmed mean, median) describe what the crowd said
accurately, and in doing so preserve the dampened signal.

The plain geometric mean performed poorly because it extremises probabilities directly rather than
in log-odds space, collapsing toward 0% on questions where the crowd was genuinely uncertain.

The advantage over the nearest competitor was tested with a Diebold-Mariano test (DM = -12.3,
p < 0.001).

## Extension: weighting forecasters by track record

The geometric mean of odds treats every forecaster's opinion as equally valuable. In practice,
forecasting skill varies, and some individuals are systematically more accurate than others.

I built a skill-weighted geometric mean of odds. For each forecaster, I computed their historical
mean Brier score across resolved questions using their most recent forecast, then assigned a weight
of `1 / (historical_brier + 0.05)`.

Design decisions:

- **Regularisation.** The 0.05 floor caps how far any single forecaster's weight can exceed the
  average, preventing a handful of strong performers from dominating the aggregate.
- **Minimum track record.** Forecasters with fewer than five resolved questions receive no
  personalised weight, since there is too little evidence of their accuracy.
- **Robust fallback.** Those forecasters are not excluded; they contribute at average weight, which
  preserves crowd breadth on questions with few experienced participants.

| Method | Mean Brier score |
|---|---|
| **Skill-weighted geometric mean of odds** | **0.1098** |
| Geometric mean of odds | 0.1104 |
| Trimmed mean | 0.1123 |
| Raw mean | 0.1125 |
| Geometric mean | 0.1136 |
| Median | 0.1138 |

The improvement works because it introduces genuinely new information — individual forecaster
quality — rather than transforming the same aggregate signal a different way.

## Limitations

Three caveats I would want addressed before anyone relied on this.

**The skill-weighting result is in-sample.** Forecaster weights are derived from performance on
resolved questions, and the weighted aggregate is then scored on those same questions. The 0.0006
Brier point gain should be read as an upper bound. Splitting questions by resolution date, deriving
weights only from earlier ones and scoring on later ones, is the natural next step.

**Scoring weights question-days equally.** Every question-answer-day contributes equally to the
mean Brier score, so long-running questions carry more weight than short ones. A per-question mean
would answer a slightly different question and might rank the methods differently.

**The significance test is approximate.** The Diebold-Mariano test assumes a single time series of
errors. Applied to a pooled panel whose errors are correlated within questions, its p-value is
likely anti-conservative. It is directional evidence that the geometric mean of odds beats the
trimmed mean, not an exact significance level; a block bootstrap clustered by question would be
stricter.

## Repository contents

- `analysis/aggregation_analysis.R` — cleaning, aggregation, scoring and the skill-weighted method
- `memo.pdf` — written summary of the analysis and results

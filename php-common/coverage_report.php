<?php
/*
 * coverage_report.php — aggregator run inside the container to summarise
 * the JSONL coverage log produced by pcov_hook.php.
 *
 * Invoked from the host via:
 *     docker compose exec <service> php /tracelib-support/coverage_report.php
 *
 * For each PHP file, we take the UNION of hit line numbers across every
 * request, and use the largest executable-line count we've seen as the
 * denominator. Overall coverage is the sum-of-unions divided by the
 * sum-of-executables.
 */

$file = '/coverage/coverage.jsonl';
if (!file_exists($file)) {
    fwrite(STDERR, "coverage_report: no data yet ($file missing)\n");
    exit(2);
}

$fp = fopen($file, 'r');
if (!$fp) {
    fwrite(STDERR, "coverage_report: cannot open $file\n");
    exit(1);
}

$requests = 0;
$status   = [];   // http status => request count
$hit_set  = [];   // file => [line => true]
$exec_max = [];   // file => largest executable-line count seen

while (($line = fgets($fp)) !== false) {
    $rec = json_decode(trim($line), true);
    if (!is_array($rec)) {
        continue;
    }
    $requests++;
    $s = $rec['status'] ?? 'unknown';
    $status[$s] = ($status[$s] ?? 0) + 1;

    foreach (($rec['covered'] ?? []) as $f => $info) {
        /* Backwards compat: earlier format stored plain integer hit counts.
         * Treat it as {h:[], e:N} with no line-level data. */
        if (is_int($info)) {
            $hit_count = $info;
            $exec      = max($exec_max[$f] ?? 0, $hit_count);
            $exec_max[$f] = $exec;
            if (!isset($hit_set[$f])) {
                $hit_set[$f] = [];
            }
            /* Without line numbers we can only approximate. Use synthetic
             * keys so we don't double-count across records. */
            for ($i = 0; $i < $hit_count; $i++) {
                $hit_set[$f]['_approx_' . $i] = true;
            }
            continue;
        }
        if (!is_array($info)) {
            continue;
        }
        $hit  = $info['h'] ?? [];
        $exec = (int)($info['e'] ?? 0);
        if (!isset($hit_set[$f])) {
            $hit_set[$f] = [];
        }
        foreach ($hit as $ln) {
            $hit_set[$f][(int)$ln] = true;
        }
        if (($exec_max[$f] ?? 0) < $exec) {
            $exec_max[$f] = $exec;
        }
    }
}
fclose($fp);

$file_covered = [];   // file => union-hit count
foreach ($hit_set as $f => $lines) {
    $file_covered[$f] = count($lines);
}

$total_hit  = array_sum($file_covered);
$total_exec = array_sum($exec_max);
$overall_pct = $total_exec > 0 ? (100.0 * $total_hit / $total_exec) : 0.0;

printf(
    "coverage_report: %d request(s), %d PHP files, %d / %d lines covered (%.2f%%)\n",
    $requests,
    count($exec_max),
    $total_hit,
    $total_exec,
    $overall_pct
);

if (!empty($status)) {
    printf("  status breakdown: ");
    $first = true;
    foreach ($status as $s => $c) {
        printf("%s%s=%d", $first ? '' : ', ', (string)$s, $c);
        $first = false;
    }
    printf("\n");
}

/* Rank by absolute covered lines, but show percentage too. */
arsort($file_covered);
$top = array_slice($file_covered, 0, 15, true);
printf("  top 15 files by covered lines (hit / executable, %%):\n");
foreach ($top as $f => $n) {
    $e   = $exec_max[$f] ?? 0;
    $pct = $e > 0 ? (100.0 * $n / $e) : 0.0;
    printf("    %5d / %5d  %6.2f%%  %s\n", $n, $e, $pct, $f);
}
if (count($file_covered) > 15) {
    printf("    ... (%d more files)\n", count($file_covered) - 15);
}

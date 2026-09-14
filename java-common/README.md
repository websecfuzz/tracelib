# Java coverage helpers

JVM targets are instrumented with the [JaCoCo](https://www.jacoco.org/jacoco/)
agent instead of a language-native runtime hook, because the JVM has no
equivalent of `runtime/coverage.WriteCountersDir` (Go), `v8.takeCoverage()`
(Node) or `Coverage.peek_result` (Ruby).

The agent is attached with `output=tcpserver`, which gives the same property the
other backends have: counters can be pulled from the running process at any
moment, without stopping it and without waiting for JVM exit.

```
-javaagent:/tracelib-support/jacocoagent.jar=output=tcpserver,address=127.0.0.1,port=6300,includes=<app packages>
```

`coverage_report.sh` is what the campaign runs inside the container. It dumps
the live counters over that socket, renders a JaCoCo XML report against the
application's class files and prints the one-line summary every other
aggregator prints, so `eval/run_campaign_v6.sh` needs no special casing beyond
the `java` runtime label:

```
coverage_report: <files> files, <hit> / <total> lines covered (<pct>%)
coverage_hash: <sha256 of sorted covered file:line entries>
coverage_item: <covered file:line>       # TRACELIB_COVERAGE_INCLUDE_ITEMS=1
```

`TRACELIB_COVERAGE_RESET=1` adds `--reset` to the dump, which is how the
per-request alignment protocol clears counters between requests.

Each image sets `JACOCO_CLASSFILES` to the class tree the report is computed
over — the application's own classes, not the framework's, so the denominator
means the same thing it does for the other runtimes.

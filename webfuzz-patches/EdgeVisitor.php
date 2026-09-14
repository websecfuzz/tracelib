<?php

// Patched copy of webFuzz/instrumentor/src/visitors/EdgeVisitor.php.
//
// Difference vs upstream:
//  1. The HTTP-method module stub registers the shutdown writer as a
//     closure rather than a named global function. Upstream's
//     `register_shutdown_function("____instr_write_map")` resolves
//     against the global namespace, which fails when the instrumented
//     file declares a namespace (the function ends up inside that
//     namespace and PHP can't find it at shutdown). Closures bind to
//     the current scope without that namespace dance.
//  2. The shutdown writer skips out when no HTTP_REQ_ID is set on the
//     request. Otherwise, every install-hook / app-init / smoke-probe
//     PHP invocation writes `/var/instr/map.0`, which (a) is useless
//     coverage data, (b) trips a "Permission denied" fatal error when
//     the bind-mounted /var/instr is owned by a uid the PHP process
//     can't write through (common in rootless docker), and (c) on phpBB
//     the fatal in install.disabled/phpbbcli.php fights with phpbbcli's
//     own preflight checks, leaving the site in an un-installed state
//     where every request bounces through a recursive /install/install/
//     redirect loop.

require_once(__DIR__ . "/../../vendor/autoload.php");

use App\BasicBlockVisitorAbstract;

class EdgeVisitor extends BasicBlockVisitorAbstract {
   protected function makeBasicBlockStub() {
      $uid = random_int(256, 268435456);
      $this->numBlocksInstrumented += 1;

      $code = '$____key = '.$uid.' ^ $GLOBALS["____instr"]["prev"];'.
              'isset($GLOBALS["____instr"]["map"][$____key]) ?: $GLOBALS["____instr"]["map"][$____key] = 0;'.
              '$GLOBALS["____instr"]["map"][$____key] += 1;'.
              '$GLOBALS["____instr"]["prev"] = '. ($uid >> 1) .';';

      return $this->codeToNodes($code);
   }

   protected function makeModuleStubFile() {
      // Capture HTTP_REQ_ID up-front via use(). phpBB clears $_SERVER
      // during request processing as a hardening measure, so reading
      // $_SERVER["HTTP_REQ_ID"] inside the shutdown closure returns empty.
      // pcov_hook.php has the same workaround for the same reason.
      // RQ2 capture support: webFuzz's native mode sends only `REQ-ID:
      // <worker_id>`, which is constant across the whole campaign with
      // -w 1. Keying the map filename on HTTP_REQ_ID alone causes every
      // request to overwrite a single map.<worker_id> file — fine for
      // the runtime feedback loop (webFuzz reads it once per request)
      // but disastrous for offline per-request signal-quality analysis,
      // which needs the file to PERSIST across requests.
      //
      // php-common/pcov_hook.php (which runs first via auto_prepend) now
      // injects $_SERVER['HTTP_X_REQUEST_ID'] = "synth-<random>" when
      // webFuzz hasn't supplied one. Below we write TWO files per
      // request when both ids exist: map.<worker_id> for runtime
      // feedback (untouched), AND map.<x_request_id> for offline RQ2
      // analysis. In TraceLib mode webFuzz already supplies a unique
      // X-REQUEST-ID; the two writes still happen and are harmless.
      $code = 'if (! array_key_exists("____instr", $GLOBALS)) {'.
              '   $GLOBALS["____instr"]["map"] = array();'.
              '   $GLOBALS["____instr"]["prev"] = 0;'.
              '   $GLOBALS["____instr"]["req_id_x"] = isset($_SERVER["HTTP_X_REQUEST_ID"]) ? (string)$_SERVER["HTTP_X_REQUEST_ID"] : "";'.
              '   $GLOBALS["____instr"]["req_id_w"] = isset($_SERVER["HTTP_REQ_ID"])       ? (string)$_SERVER["HTTP_REQ_ID"]       : "";'.
              '   register_shutdown_function(function () {'.
              '      $rx = $GLOBALS["____instr"]["req_id_x"] ?? "";'.
              '      $rw = $GLOBALS["____instr"]["req_id_w"] ?? "";'.
              '      if ($rx === "" && $rw === "") { return; }'.
              '      $write_to = function ($name) {'.
              '          if (preg_match("/[^A-Za-z0-9_-]/", $name)) { return; }'.
              '          $f = @fopen("/var/instr/map." . $name, "w+");'.
              '          if (! $f) { return; }'.
              '          foreach ($GLOBALS["____instr"]["map"] as $k=>$v) {'.
              '              fwrite($f, $k . "-" . $v . "\n");'.
              '          }'.
              '          fclose($f);'.
              '      };'.
              '      if ($rw !== "") { $write_to($rw); }'.
              '      if ($rx !== "" && $rx !== $rw) { $write_to($rx); }'.
              '   });'.
              '}';

      return $this->codeToNodes($code);
   }

   protected function makeModuleStubHttp() {
      $code = 'if (! array_key_exists("____instr", $GLOBALS)) {'.
              '   $GLOBALS["____instr"]["map"] = array();'.
              '   $GLOBALS["____instr"]["prev"] = 0;'.
              '   register_shutdown_function(function () {'.
              '      foreach ($GLOBALS["____instr"]["map"] as $k=>$v) {'.
              '          header("I-" . $k . ": " . $v);'.
              '      }'.
              '   });'.
              '   ob_start(null, 0, 0);'.
              '}';

      return $this->codeToNodes($code);
   }
}

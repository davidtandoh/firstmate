# Consumer validation for Omnigent and PAK schema 1 receipts.
# Inputs are the independently selected installer receipt, not measured values
# copied back as their own expected values. Native wrapper capability remains
# a separate CLI probe owned by fm-omnigent.sh.
# Load with jq -L bin 'include "fm-omnigent-contract"; ...' on slurped input.
# Runtime verification returns a boolean. Refusal projection emits only a known
# category; an invalid envelope emits nothing, so jq -e refuses it.
def absolute_path:
  type == "string" and startswith("/") and
  (test("[\u0000-\u001f\u007f]") | not) and
  (split("/")[1:] | all(. != "" and . != "." and . != ".."));
def exact_environment_names:
  ["CODEX_HOME", "OMNIGENT_AUTH_PROVIDER", "OMNIGENT_CODEX_PATH", "OMNIGENT_CONFIG_HOME", "OMNIGENT_DATA_DIR",
   "OMNIGENT_LOCAL_SERVER_PORT", "OMNIGENT_WEB_BASE_PATH"];
def valid_client_environment:
  type == "object" and all(to_entries[];
    (.key as $key | exact_environment_names | index($key) != null) and
    (.value | type == "string" and (test("[\u0000-\u001f\u007f]") | not)));
def valid_runtime_identity:
  type == "object" and
  keys == ["executable", "generation", "package_version", "python", "source_commit", "state_schema"] and
  (.executable | absolute_path) and (.python | absolute_path) and
  (.generation | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
  (.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.package_version | type == "string" and length > 0) and .state_schema == 1;
def valid_port:
  type == "string" and test("^[1-9][0-9]{0,4}$") and tonumber <= 65535;
def loopback_endpoint_port:
  try ((capture("^http://(?:127\\.0\\.0\\.1|localhost|\\[::1\\]):(?<port>[0-9]+)$").port |
    select(valid_port)) // null) catch null;
def fm_omnigent_runtime_verified($executable; $generation; $commit; $server; $environment):
try (length == 1 and (.[0] |
  type == "object" and .schema_version == 1 and .availability == "ready" and
  (.runtime | valid_runtime_identity and .executable == $executable and
    .generation == $generation and .source_commit == $commit) and
  .endpoint == $server and
  (.endpoint | loopback_endpoint_port != null) and
  (.allowed_client_environment | type == "array" and sort == exact_environment_names) and
  .client_environment == $environment and
  (.client_environment | valid_client_environment) and
  (.native_environment | type == "object" and .interface == "--env KEY=VALUE" and .max_entries == 64 and
    .max_total_bytes == 65536 and .ambient_forwarding == false) and
  .telemetry == {owner:"external",admission:"external_policy"})) catch false;
def fm_omnigent_runtime_matches($runtime; $server; $environment):
  try (fm_omnigent_runtime_verified($runtime.executable; $runtime.generation;
    $runtime.source_commit; $server; $environment) and
  (.[0].runtime == $runtime)) catch false;
def fm_omnigent_selector_verified:
  try (length == 1 and (.[0] | . as $selection |
    type == "object" and
    keys == ["client_environment", "endpoint", "installer", "owner", "runtime", "schema_version"] and
    .schema_version == 1 and .owner == "pak" and
    (.runtime | valid_runtime_identity) and
    (.installer | type == "object" and
      keys == ["component", "environment", "generation", "manifest_sha256"] and
      .component == "omnigent" and (.environment | absolute_path) and
      (.generation | type == "string" and test("^[0-9a-f]{32}$")) and
      (.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.runtime.executable | startswith($selection.installer.environment + "/")) and
    (.client_environment | type == "object" and
      keys == ["OMNIGENT_CONFIG_HOME", "OMNIGENT_DATA_DIR", "OMNIGENT_LOCAL_SERVER_PORT"] and
      (.OMNIGENT_CONFIG_HOME | absolute_path) and (.OMNIGENT_DATA_DIR | absolute_path) and
      (.OMNIGENT_LOCAL_SERVER_PORT | valid_port)) and
    (.endpoint | loopback_endpoint_port) == .client_environment.OMNIGENT_LOCAL_SERVER_PORT)) catch false;
def valid_harness_capabilities:
  . as $caps | type == "object" and
  all(["integration_mode", "elicitation", "resume", "effort", "model_family",
       "auth", "fork_history", "instruction_delivery"][]; . as $key |
    ($caps[$key] | type == "string")) and
  all(["subagents", "interrupt", "streaming"][]; . as $key |
    ($caps[$key] | type == "boolean")) and
  all(["steering", "live_queue", "images", "compaction"][]; . as $key |
    ($caps | has($key)) and ($caps[$key] | type == "boolean" or type == "null")) and
  all(["shell_tool_name", "shell_tool_prompt"][]; . as $key |
    ($caps | has($key)) and ($caps[$key] | type == "string" or type == "null"));
def fm_omnigent_harness_verified($harness):
  try (length == 1 and (.[0] |
    type == "object" and .schema_version == 1 and
    (.harnesses | type == "array" and
      all(.[];
        type == "object" and (.id | type == "string" and length > 0) and
        (.command | type == "string" and length > 0) and
        (.durable_custody | type == "boolean") and
        (.capabilities | valid_harness_capabilities)) and
      (map(.id) | unique | length) == length and
      (map(.command) | unique | length) == length and
      ([.[] | select(.command == $harness)] | length) == 1))) catch false;
# PAK telemetry validation uses the exact owner policy fields.
# Loss null remains unknown. This predicate neither starts nor stops a session.
def telemetry_environment_names($capture):
  (["OMNIGENT_TELEMETRY_ENABLED", "OMNIGENT_OTEL_CAPTURE_CONTENT",
    "OMNIGENT_OTEL_HTTP_CLIENT_INSTRUMENTATION", "OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER"] +
   (if $capture then ["OTEL_EXPORTER_OTLP_PROTOCOL", "OTEL_EXPORTER_OTLP_ENDPOINT",
                     "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_HEADERS"] else [] end)) | sort;
def redactor_url:
  type == "string" and test("^http://127\\.0\\.0\\.1:[0-9]+$") and
  (split(":")[-1] | valid_port);
def fm_omnigent_telemetry_verified:
  try (length == 1 and (.[0] | . as $policy |
    type == "object" and
    keys == (["schema_version", "owner", "session_scope", "work_session_policy", "capture_enabled",
      "collection_required", "delivery_available", "admission", "reason", "existing_sessions",
      "durable_acceptance", "redactor_endpoint", "client_environment", "loss", "retry"] | sort) and
    .schema_version == 1 and .owner == "pak" and
    (.session_scope | IN("personal", "client", "employer", "bigspark-kiro")) and
    (.capture_enabled | type == "boolean") and
    (.collection_required | type == "boolean") and
    (.delivery_available | type == "boolean") and
    (if .session_scope == "personal" then .work_session_policy == null
     else (.work_session_policy | IN("exclude", "tag")) and
       .capture_enabled == (.work_session_policy == "tag") end) and
    ((.collection_required | not) or .capture_enabled) and
    .existing_sessions == "preserve" and .durable_acceptance == false and
    (.loss == null or (.loss | type == "object" and
      keys == ["accepted_batches", "delivered_batches", "dropped_batches", "queue_rejected_batches", "retry_attempts"] and
      all(.[]; type == "number" and . >= 0 and floor == .))) and
    .retry == {max_attempts:3,memory_queue_items:64,memory_queue_bytes:67108864} and
    (.client_environment | type == "object" and
      keys == telemetry_environment_names($policy.capture_enabled) and
      all(.[]; type == "string" and (test("[\u0000-\u001f\u007f]") | not)) and
      .OMNIGENT_TELEMETRY_ENABLED == ($policy.capture_enabled | tostring) and
      .OMNIGENT_OTEL_CAPTURE_CONTENT == ($policy.capture_enabled | tostring) and
      .OMNIGENT_OTEL_HTTP_CLIENT_INSTRUMENTATION == "false" and
      .OTEL_METRICS_EXPORTER == "none" and .OTEL_LOGS_EXPORTER == "none") and
    (if .capture_enabled then
       (.redactor_endpoint | redactor_url) and
       .client_environment.OTEL_EXPORTER_OTLP_PROTOCOL == "http/protobuf" and
       .client_environment.OTEL_EXPORTER_OTLP_ENDPOINT == .redactor_endpoint and
       .client_environment.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT == (.redactor_endpoint + "/v1/traces") and
       (.client_environment.OTEL_EXPORTER_OTLP_TRACES_HEADERS | test("^x-mlflow-experiment-id=[0-9]+$"))
     else .redactor_endpoint == null end) and
    (if .collection_required and (.delivery_available | not) then
       .admission == "deny_new" and .reason == "required_collection_unavailable"
     elif .capture_enabled and (.delivery_available | not) then
       .admission == "allow_with_gap" and .reason == "telemetry_gap"
     else .admission == "allow" and .reason == null end))) catch false;
def fm_omnigent_error_category:
  if length == 1 and (.[0] | type == "object" and .schema_version == 1 and
      (.error | type == "object" and
        (.category | IN("invalid_endpoint", "endpoint_unavailable", "endpoint_mismatch",
                       "auth_denied", "runtime_unverified", "runtime_mismatch"))))
  then .[0].error.category else empty end;
def fm_pak_error_category:
  if length == 1 and (.[0] | .schema_version == 1 and .status == "refused" and
      .error.category == "unavailable_probe")
  then "unavailable_probe" else empty end;

def identity_string:
  type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not);
def positive_integer:
  type == "number" and . > 0 and floor == .;
def nonnegative_integer:
  type == "number" and . >= 0 and floor == .;
def digest_string:
  type == "string" and test("^[0-9a-f]{64}$");
def process_identity:
  type == "object" and keys == ["boot_id", "pid", "pid_ns", "started_at"] and
  (.pid | positive_integer) and (.started_at | type == "number" and . > 0) and
  .pid_ns == "none" and .boot_id == null;
def fm_omnigent_binding_verified($workspace; $endpoint):
  try (length == 1 and (.[0] |
    type == "object" and keys == ["config_digest", "endpoint", "environment_digest", "harness",
      "host_id", "native", "owner", "owner_generation", "runner_id", "schema_version", "session_id", "terminal", "workspace"] and
    .schema_version == 1 and .harness == "codex-native" and
    (.session_id | identity_string) and (.runner_id | identity_string) and
    (.owner_generation | identity_string) and (.host_id | identity_string) and
    (.workspace | absolute_path) and .workspace == $workspace and .endpoint == $endpoint and
    (.endpoint | loopback_endpoint_port != null) and
    (.config_digest | digest_string) and (.environment_digest | digest_string) and
    (.owner | process_identity) and (.native | process_identity) and
    (.terminal | type == "object" and
      keys == ["device", "inode", "name", "pane", "session_key", "socket", "tmux"] and
      .name == "codex/main" and (.session_key | identity_string) and (.socket | absolute_path) and
      (.device | nonnegative_integer) and (.inode | positive_integer) and
      (.tmux | process_identity) and (.pane | process_identity)))) catch false;
def fm_omnigent_binding_error_category:
  if length == 1 and (.[0] | type == "object" and .schema_version == 1 and
      (.error.category | IN("record_mismatch", "scope_mismatch", "config_mismatch", "binding_mismatch",
        "stale_attachment", "foreign_socket", "unsupported_custody", "unavailable_probe", "launch_unavailable")))
  then .[0].error.category else empty end;

# Intentional end verifies its exact bound scope through the owner, not a
# caller config digest. This is an owner-ended receipt, not pane liveness.
def fm_omnigent_end_verified($binding):
  try (length == 1 and (.[0] | type == "object" and
    keys == ["owner_generation", "schema_version", "session_id", "state"] and
    .schema_version == 1 and .state == "ended" and
    .session_id == $binding.session_id and .owner_generation == $binding.owner_generation)) catch false;

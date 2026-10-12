# Verify the runtime portion of Omnigent runtime launch-contract schema 1.
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
  ["OMNIGENT_AUTH_PROVIDER", "OMNIGENT_CONFIG_HOME", "OMNIGENT_DATA_DIR",
   "OMNIGENT_LOCAL_SERVER_PORT", "OMNIGENT_WEB_BASE_PATH"];
def fm_omnigent_runtime_verified($executable; $generation; $commit; $server; $environment):
try (length == 1 and (.[0] |
  type == "object" and .schema_version == 1 and .availability == "ready" and
  (.runtime | type == "object" and
    .executable == $executable and (.executable | absolute_path) and
    (.python | absolute_path) and
    .generation == $generation and (.generation | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .source_commit == $commit and (.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
    (.package_version | type == "string" and length > 0) and .state_schema == 1) and
  .endpoint == $server and
  (.endpoint | type == "string" and test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]+$")) and
  .allowed_client_environment == exact_environment_names and
  .client_environment == $environment and
  (.client_environment | type == "object" and
    all(to_entries[];
      (.key as $key | exact_environment_names | index($key) != null) and
      (.value | type == "string" and (test("[\u0000-\u001f\u007f]") | not)))) and
  (.native_environment | type == "object" and .max_entries == 64 and
    .max_total_bytes == 65536 and .ambient_forwarding == false) and
  .telemetry == {owner:"external",admission:"external_policy"})) catch false;
def fm_omnigent_error_category:
  if length == 1 and (.[0] | type == "object" and .schema_version == 1 and
      (.error | type == "object" and
        (.category | IN("invalid_endpoint", "endpoint_unavailable", "endpoint_mismatch",
                       "auth_denied", "runtime_unverified", "runtime_mismatch"))))
  then .[0].error.category else empty end;

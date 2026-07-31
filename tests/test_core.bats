#!/usr/bin/env bats

setup() {
  load '../lib/stack-updater-core.sh'
}

@test "compose_image_lines_from_content extracts image lines" {
  run compose_image_lines_from_content $'services:\n  web:\n    image: nginx:alpine\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nginx:alpine"* ]]
}

@test "compose_image_lines_from_content strips quotes and comments" {
  run compose_image_lines_from_content $'services:\n  web:\n    image: "postgres:16" # pinned\n'
  [ "$status" -eq 0 ]
  [ "$output" = "postgres:16" ]
}

@test "_cup_image_refs_equivalent matches library shorthand" {
  _cup_image_refs_equivalent "postgres:16" "docker.io/library/postgres:16"
  [ "$?" -eq 0 ]
}

@test "normalize_image_ref_token trims and strips digest comments" {
  run normalize_image_ref_token '  "nginx:alpine" # latest'
  [ "$output" = "nginx:alpine" ]
}

@test "portainer_normalize_version_sortkey strips prefix" {
  run portainer_normalize_version_sortkey "v2.39.1 LTS"
  [ "$output" = "2.39.1" ]
}

@test "_format_duration_secs formats minutes" {
  run _format_duration_secs 125
  [ "$output" = "2m 5s" ]
}

@test "_format_mm_ss formats clock style" {
  run _format_mm_ss 125
  [ "$output" = "02:05" ]
}

@test "stack_updater_cron_valid accepts daily expression" {
  stack_updater_cron_valid "0 4 * * *"
  [ "$?" -eq 0 ]
}

@test "stack_updater_cron_valid rejects bad field count" {
  stack_updater_cron_valid "0 4 * *"
  [ "$?" -ne 0 ]
}

@test "compose_project_slug_from_stack_name normalizes" {
  run compose_project_slug_from_stack_name "My VPN Stack"
  [ "$output" = "my-vpn-stack" ]
}

@test "cup_outdated_image_lines_from_json lists outdated refs" {
  local json='{"images":[{"reference":"nginx:alpine","result":{"has_update":true}},{"reference":"redis:7","result":{"has_update":false}}]}'
  run cup_outdated_image_lines_from_json "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nginx:alpine"* ]]
  [[ "$output" != *"redis:7"* ]]
}

@test "cup_outdated_detail_lines_from_json includes version arrow" {
  local json='{"images":[{"reference":"nginx:alpine","result":{"has_update":true,"info":{"current_version":"1.25","new_version":"1.27","version_update_type":"minor"}}},{"reference":"redis:7","result":{"has_update":false}}]}'
  run cup_outdated_detail_lines_from_json "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"outdated: nginx:alpine 1.25 → 1.27 minor"* ]]
  [[ "$output" != *"redis:7"* ]]
}

@test "compose_images_match_cup_outdated matches compose image" {
  local compose='services:\n  web:\n    image: nginx:alpine\n'
  local json='{"images":[{"reference":"docker.io/library/nginx:alpine","result":{"has_update":true}}]}'
  compose_images_match_cup_outdated "$compose" "$json"
  [ "$?" -eq 0 ]
  [ "$SELECTIVE_CUP_MATCH_REF" = "docker.io/library/nginx:alpine" ]
}

@test "registry_digest_from_manifest_json reads single-image digest" {
  local manifest='{"config":{"digest":"sha256:abc123"}}'
  run registry_digest_from_manifest_json "$manifest"
  [ "$output" = "sha256:abc123" ]
}

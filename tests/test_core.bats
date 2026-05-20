#!/usr/bin/env bats

setup() {
  load '../lib/stack-updater-core.sh'
}

@test "compose_image_lines_from_content extracts image lines" {
  run compose_image_lines_from_content $'services:\n  web:\n    image: nginx:alpine\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nginx:alpine"* ]]
}

@test "_cup_image_refs_equivalent matches library shorthand" {
  _cup_image_refs_equivalent "postgres:16" "docker.io/library/postgres:16"
  [ "$?" -eq 0 ]
}

@test "portainer_normalize_version_sortkey strips prefix" {
  run portainer_normalize_version_sortkey "v2.39.1 LTS"
  [ "$output" = "2.39.1" ]
}

@test "_format_duration_secs formats minutes" {
  run _format_duration_secs 125
  [ "$output" = "2m 5s" ]
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


{config, "{{ base_dir }}/resources/systest_cli.config"}.

{alias, test, "{{ base_dir }}/test-ebin"}.
{suites, test, systest_cli_SUITE}.
% {cases, test, systest_cli_SUITE, starting_and_stopping_nodes}.

{ct_hooks, [cth_log_redirect,
            {systest_supervision_cth, [], 0},
            {systest_cth, [], 1000}]}.
{enable_builtin_hooks, true}.


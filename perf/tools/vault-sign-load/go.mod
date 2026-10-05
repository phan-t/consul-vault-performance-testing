module github.com/phan-t/consul-vault-performance-testing/perf/tools/vault-sign-load

go 1.24

// Same Vault API client version as Consul 2.0.1 (its Vault CA provider).
require github.com/hashicorp/vault/api v1.16.0

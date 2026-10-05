# Same as pki-sign-consul-nostore.hcl but with no_store = false, to quantify
# what no_store buys: stored certs are Raft writes that must go to the active
# node, while no_store signing can be served by performance standbys.

test "pki_sign" "consul_leaf_store" {
  weight = 100

  config {
    setup_delay = "2s"

    root_ca {
      common_name = "perf root"
      key_type    = "ec"
      key_bits    = 256
    }

    intermediate_csr {
      common_name = "perf intermediate"
      key_type    = "ec"
      key_bits    = 256
    }

    role {
      allow_any_name    = true
      enforce_hostnames = false
      allowed_uri_sans  = "spiffe://*"
      require_cn        = false
      key_type          = "any"
      ttl               = "168h"
      max_ttl           = "168h"
      no_store          = false
    }

    sign {
      common_name = "perf-vb"
      csr         = "__CSR_FILE__"
      ttl         = "168h"
    }
  }
}

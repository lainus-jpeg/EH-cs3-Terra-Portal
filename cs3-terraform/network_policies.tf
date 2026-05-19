# ══════════════════════════════════════════════════════════════════════════════
# KUBERNETES NETWORK POLICIES — Zero Trust micro-segmentation
# Default deny all, then explicitly allow only required traffic
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. Default deny all ingress+egress in default namespace ───────────────────
resource "kubernetes_network_policy" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = "default"
  }

  spec {
    pod_selector {} # applies to ALL pods in namespace

    policy_types = ["Ingress", "Egress"]
    # No ingress/egress rules = deny everything
  }

  depends_on = [module.eks]
}

# ── 2. Default deny all in monitoring namespace ────────────────────────────────
resource "kubernetes_network_policy" "monitoring_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ── 3. Frontend policy ─────────────────────────────────────────────────────────
# Ingress: allow from ALB (anywhere on port 80)
# Egress:  allow to backend on 3000 + DNS
resource "kubernetes_network_policy" "frontend" {
  metadata {
    name      = "frontend-policy"
    namespace = "default"
  }

  spec {
    pod_selector {
      match_labels = { app = "frontend" }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow inbound from ALB (no pod selector = from anywhere, ALB hits node port)
    ingress {
      ports {
        port     = "80"
        protocol = "TCP"
      }
    }

    # Allow outbound to backend only
    egress {
      to {
        pod_selector {
          match_labels = { app = "backend" }
        }
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }

    # Allow DNS resolution
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

# ── 4. Backend policy ──────────────────────────────────────────────────────────
# Ingress: allow from frontend on 3000, ALB on 3000
# Egress:  allow to RDS (5432), AWS APIs/Lambda/SSM (443), Prometheus (9090), DNS
resource "kubernetes_network_policy" "backend" {
  metadata {
    name      = "backend-policy"
    namespace = "default"
  }

  spec {
    pod_selector {
      match_labels = { app = "backend" }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow from frontend
    ingress {
      from {
        pod_selector {
          match_labels = { app = "frontend" }
        }
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }

    # Allow from ALB (health checks + direct /v1 traffic)
    ingress {
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }

    # Egress to RDS (inside VPC, any node in private subnets)
    egress {
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }

    # Egress to AWS APIs — Lambda, SSM, ECR, Secrets Manager (all HTTPS)
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    # Egress to Prometheus in monitoring namespace
    egress {
      to {
        namespace_selector {
          match_labels = { kubernetes_io_metadata_name = "monitoring" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "prometheus" }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }

    # DNS
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

# ── 5. Prometheus policy ───────────────────────────────────────────────────────
# Ingress: allow from backend (queries) + Grafana (datasource)
# Egress:  allow scraping all pods on metrics port 9090/8080, DNS
resource "kubernetes_network_policy" "prometheus" {
  metadata {
    name      = "prometheus-policy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "prometheus" }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow from backend (proxy queries)
    ingress {
      from {
        namespace_selector {
          match_labels = { kubernetes_io_metadata_name = "default" }
        }
        pod_selector {
          match_labels = { app = "backend" }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }

    # Allow from Grafana (datasource)
    ingress {
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "grafana" }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }

    # Allow port-forward from localhost (for demo)
    ingress {
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }

    # Egress — scrape metrics from all namespaces
    egress {
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }
    egress {
      ports {
        port     = "9091"
        protocol = "TCP"
      }
    }
    egress {
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
    egress {
      ports {
        port     = "10250"
        protocol = "TCP"
      }
    }

    # DNS
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.monitoring_deny]
}

# ── 6. Grafana policy ──────────────────────────────────────────────────────────
# Ingress: allow from ALB (port-forward + ingress)
# Egress:  allow to Prometheus only + DNS
resource "kubernetes_network_policy" "grafana" {
  metadata {
    name      = "grafana-policy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "grafana" }
    }

    policy_types = ["Ingress", "Egress"]

    # Allow from anywhere (ALB + port-forward)
    ingress {
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }

    # Egress to Prometheus
    egress {
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "prometheus" }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }

    # Egress HTTPS (plugin downloads, avatar service)
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    # DNS
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy.monitoring_deny]
}

# ── 7. Allow kube-system components (CoreDNS etc) ─────────────────────────────
resource "kubernetes_network_policy" "allow_kube_system" {
  metadata {
    name      = "allow-kube-system"
    namespace = "default"
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { kubernetes_io_metadata_name = "kube-system" }
        }
      }
    }
  }

  depends_on = [kubernetes_network_policy.default_deny]
}

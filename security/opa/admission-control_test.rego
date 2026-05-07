# OPA unit tests for admission-control.rego
# Run: opa test security/opa/admission-control.rego security/opa/admission-control_test.rego -v

package kubernetes.admission

# ── Helpers ──────────────────────────────────────────────────────────────────

mock_pod(name, containers) := {
  "request": {
    "kind": {"kind": "Pod"},
    "object": {
      "metadata": {
        "name": name,
        "labels": {
          "app.kubernetes.io/name":     "test-app",
          "app.kubernetes.io/instance": "test-app",
        },
      },
      "spec": {"containers": containers, "initContainers": []},
    },
  },
}

mock_deployment(name, labels, pod_labels, containers) := {
  "request": {
    "kind": {"kind": "Deployment"},
    "object": {
      "metadata": {"name": name, "labels": labels},
      "spec": {
        "template": {
          "metadata": {"labels": pod_labels},
          "spec": {"containers": containers},
        },
      },
    },
  },
}

safe_container := {
  "name": "app",
  "image": "ghcr.io/example/app:sha-abc123",
  "securityContext": {
    "allowPrivilegeEscalation": false,
    "runAsNonRoot": true,
  },
}

# ── RULE 1: allowPrivilegeEscalation ────────────────────────────────────────

test_deny_pod_privilege_escalation if {
  bad_container := json.patch(safe_container, [{"op": "replace", "path": "/securityContext/allowPrivilegeEscalation", "value": true}])
  input := mock_pod("bad-pod", [bad_container])
  count(deny) > 0
}

test_allow_pod_no_privilege_escalation if {
  input := mock_pod("good-pod", [safe_container])
  count(deny) == 0
}

test_deny_deployment_privilege_escalation if {
  bad_container := json.patch(safe_container, [{"op": "replace", "path": "/securityContext/allowPrivilegeEscalation", "value": true}])
  input := mock_deployment(
    "bad-deploy",
    {"app.kubernetes.io/name": "test", "app.kubernetes.io/instance": "test"},
    {"app.kubernetes.io/name": "test", "app.kubernetes.io/instance": "test"},
    [bad_container],
  )
  count(deny) > 0
}

# ── RULE 2: mandatory labels ──────────────────────────────────────────────────

test_deny_pod_missing_name_label if {
  input := {
    "request": {
      "kind": {"kind": "Pod"},
      "object": {
        "metadata": {
          "name": "no-name-pod",
          "labels": {"app.kubernetes.io/instance": "myapp"},
        },
        "spec": {"containers": [safe_container], "initContainers": []},
      },
    },
  }
  count(deny) > 0
}

test_deny_pod_missing_instance_label if {
  input := {
    "request": {
      "kind": {"kind": "Pod"},
      "object": {
        "metadata": {
          "name": "no-instance-pod",
          "labels": {"app.kubernetes.io/name": "myapp"},
        },
        "spec": {"containers": [safe_container], "initContainers": []},
      },
    },
  }
  count(deny) > 0
}

test_deny_deployment_missing_labels if {
  input := mock_deployment(
    "no-labels-deploy",
    {"app.kubernetes.io/name": "myapp"},
    {"app.kubernetes.io/name": "myapp"},
    [safe_container],
  )
  count(deny) > 0
}

test_allow_deployment_with_all_labels if {
  input := mock_deployment(
    "good-deploy",
    {"app.kubernetes.io/name": "myapp", "app.kubernetes.io/instance": "myapp"},
    {"app.kubernetes.io/name": "myapp", "app.kubernetes.io/instance": "myapp"},
    [safe_container],
  )
  count(deny) == 0
}

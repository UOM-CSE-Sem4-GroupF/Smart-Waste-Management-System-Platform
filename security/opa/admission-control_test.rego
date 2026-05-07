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
        "labels": {"app": "test-app", "version": "v1.0.0"},
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
    {"app": "test", "version": "v1"},
    {"app": "test", "version": "v1"},
    [bad_container],
  )
  count(deny) > 0
}

# ── RULE 2: mandatory labels ──────────────────────────────────────────────────

test_deny_pod_missing_app_label if {
  input := {
    "request": {
      "kind": {"kind": "Pod"},
      "object": {
        "metadata": {"name": "no-label-pod", "labels": {"version": "v1"}},
        "spec": {"containers": [safe_container], "initContainers": []},
      },
    },
  }
  count(deny) > 0
}

test_deny_pod_missing_version_label if {
  input := {
    "request": {
      "kind": {"kind": "Pod"},
      "object": {
        "metadata": {"name": "no-version-pod", "labels": {"app": "myapp"}},
        "spec": {"containers": [safe_container], "initContainers": []},
      },
    },
  }
  count(deny) > 0
}

test_deny_deployment_missing_labels if {
  input := mock_deployment(
    "no-labels-deploy",
    {"app": "myapp"},
    {"app": "myapp"},
    [safe_container],
  )
  count(deny) > 0
}

test_allow_deployment_with_all_labels if {
  input := mock_deployment(
    "good-deploy",
    {"app": "myapp", "version": "v1.0.0"},
    {"app": "myapp", "version": "v1.0.0"},
    [safe_container],
  )
  count(deny) == 0
}

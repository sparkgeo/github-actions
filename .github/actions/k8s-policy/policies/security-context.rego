# Containers must run as non-root and must not be privileged.
package main

# runAsNonRoot may be set on the pod or the container; a container-level
# `false` overrides a pod-level `true`.
runs_as_non_root(c) if c.securityContext.runAsNonRoot == true

runs_as_non_root(c) if {
	pod_spec.securityContext.runAsNonRoot == true
	not c.securityContext.runAsNonRoot == false
}

# An explicit UID 0 at container level, or at pod level with no container override.
runs_as_uid0(c) if c.securityContext.runAsUser == 0

runs_as_uid0(c) if {
	pod_spec.securityContext.runAsUser == 0
	not c.securityContext.runAsUser
}

deny contains msg if {
	some c in containers
	not runs_as_non_root(c)
	msg := sprintf("%s: must run as non-root (securityContext.runAsNonRoot: true on the pod or the container)", [container_subject(c)])
}

deny contains msg if {
	some c in containers
	runs_as_uid0(c)
	msg := sprintf("%s: must not run as root (securityContext.runAsUser: 0)", [container_subject(c)])
}

deny contains msg if {
	some c in containers
	c.securityContext.privileged == true
	msg := sprintf("%s: securityContext.privileged must not be true", [container_subject(c)])
}

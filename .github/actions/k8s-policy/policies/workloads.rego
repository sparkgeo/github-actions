# Shared helpers: locate the pod spec and containers of any workload kind.
package main

# Pod spec for every kind that embeds one.
pod_spec := input.spec if input.kind == "Pod"

pod_spec := input.spec.template.spec if {
	input.kind in {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
}

pod_spec := input.spec.jobTemplate.spec.template.spec if input.kind == "CronJob"

# App containers and init containers are held to the same rules.
containers contains c if some c in pod_spec.containers

containers contains c if some c in pod_spec.initContainers

subject := sprintf("%s/%s", [input.kind, input.metadata.name])

container_subject(c) := sprintf("%s container %s", [subject, c.name])

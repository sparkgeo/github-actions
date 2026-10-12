# Sparkgeo tagging standard as Kubernetes labels (issue #114). Dormant unless
# policies/tags/standard.yml is loaded as data (data.tags.enforce == true); the
# k8s-policy composite does that when require-tags is on.
package main

taggable_kinds := {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod", "Namespace"}

tags_enforced if data.tags.enforce == true

deny contains msg if {
	tags_enforced
	input.kind in taggable_kinds
	some key, _ in data.tags.required
	not input.metadata.labels[key]
	msg := sprintf("%s: missing required label %q", [subject, key])
}

deny contains msg if {
	tags_enforced
	input.kind in taggable_kinds
	some key, spec in data.tags.required
	value := input.metadata.labels[key]
	spec.enum
	not value in spec.enum
	msg := sprintf("%s: label %s=%q is not one of %s", [subject, key, value, concat(", ", spec.enum)])
}

deny contains msg if {
	tags_enforced
	input.kind in taggable_kinds
	some key, spec in data.tags.required
	value := input.metadata.labels[key]
	pattern := object.get(spec, "label_pattern", object.get(spec, "pattern", ""))
	pattern != ""
	not regex.match(pattern, value)
	msg := sprintf("%s: label %s=%q does not match %s", [subject, key, value, pattern])
}

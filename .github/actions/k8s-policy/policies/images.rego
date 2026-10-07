# Images must come from an approved registry and be pinned to a tag or digest.
#
# Override the registry list from a consumer data file (--data / data-path):
#   k8s_policy:
#     allowed_registries: ["ghcr.io", "*.dkr.ecr.*.amazonaws.com"]
# Entries are glob patterns matched against the registry host, "." delimited.
package main

default allowed_registries := ["ghcr.io", "cgr.dev", "public.ecr.aws", "*.dkr.ecr.*.amazonaws.com"]

allowed_registries := data.k8s_policy.allowed_registries

# Registry host of an image reference. A first path segment that contains a
# "." or ":" (or is "localhost") is a host; anything else is Docker Hub.
registry(image) := host if {
	parts := split(image, "/")
	count(parts) > 1
	host := parts[0]
	looks_like_host(host)
} else := "docker.io"

looks_like_host(h) if contains(h, ".")

looks_like_host(h) if contains(h, ":")

looks_like_host("localhost")

registry_allowed(image) if {
	some pattern in allowed_registries
	glob.match(pattern, ["."], registry(image))
}

pinned(image) if contains(image, "@")

pinned(image) if {
	not contains(image, "@")
	parts := split(image, "/")
	last := parts[count(parts) - 1]
	contains(last, ":")
	tag := split(last, ":")[1]
	tag != "latest"
}

deny contains msg if {
	some c in containers
	not registry_allowed(c.image)
	msg := sprintf("%s: image %q is not from an allowed registry (%s)", [container_subject(c), c.image, concat(", ", allowed_registries)])
}

deny contains msg if {
	some c in containers
	not pinned(c.image)
	msg := sprintf("%s: image %q uses the latest tag or no tag; pin a tag or digest", [container_subject(c), c.image])
}

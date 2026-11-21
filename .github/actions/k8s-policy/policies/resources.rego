# Every container must declare CPU/memory requests and a memory limit so the
# scheduler can place it and the kernel can bound it. A CPU limit is left to
# the team: throttling is usually worse than a request-only CPU share.
package main

required_resources := ["requests.cpu", "requests.memory", "limits.memory"]

missing_resources(c) := [r |
	some r in required_resources
	path := array.concat(["resources"], split(r, "."))
	object.get(c, path, null) == null
]

deny contains msg if {
	some c in containers
	missing := missing_resources(c)
	count(missing) > 0
	msg := sprintf("%s: must set resources.requests.cpu, resources.requests.memory, resources.limits.memory (missing: %s)", [container_subject(c), concat(", ", missing)])
}

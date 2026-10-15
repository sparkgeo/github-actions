// Package auth is a high-risk path (**/auth/**) with a fuzz target and no property.
package auth

// Allowed reports whether role may write.
func Allowed(role string) bool { return role == "admin" || role == "editor" }

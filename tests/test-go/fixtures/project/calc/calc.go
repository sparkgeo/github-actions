// Package calc is a fixture for the test-go reusable workflow.
package calc

import "errors"

// ErrDivideByZero is returned by Divide when b is zero.
var ErrDivideByZero = errors.New("division by zero")

// Add returns a + b.
func Add(a, b int) int {
	return a + b
}

// Divide returns a / b or ErrDivideByZero.
func Divide(a, b int) (int, error) {
	if b == 0 {
		return 0, ErrDivideByZero
	}
	return a / b, nil
}

package calc

import "testing"

func TestAdd(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2, 3) = %d, want 5", got)
	}
}

func TestDivide(t *testing.T) {
	got, err := Divide(6, 3)
	if err != nil || got != 2 {
		t.Fatalf("Divide(6, 3) = %d, %v; want 2, nil", got, err)
	}
}

func TestDivideByZero(t *testing.T) {
	if _, err := Divide(1, 0); err != ErrDivideByZero {
		t.Fatalf("Divide(1, 0) error = %v, want ErrDivideByZero", err)
	}
}

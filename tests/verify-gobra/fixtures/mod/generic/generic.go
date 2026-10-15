// Generics: valid Go that Gobra v26.02 cannot parse (unsupported).
package generic

func Identity[T any](x T) T { return x }

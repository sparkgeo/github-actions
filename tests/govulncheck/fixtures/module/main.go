// Fixture for the govulncheck composite (issue #180). golang.org/x/text
// v0.3.6 carries GO-2021-0113 (language.Parse, reached through MustParse
// below) and GO-2022-1059 (language.ParseAcceptLanguage, imported but never
// called), so one finding is reachable and one is not.
package main

import (
	"fmt"

	"golang.org/x/text/language"
)

func main() {
	fmt.Println(language.MustParse("en-US"))
}

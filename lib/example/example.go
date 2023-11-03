package example

import "fmt"

// Example shows that all exported symbols must have a comment like this.
type Example struct {}

// Print shows that the exported symbol comments applies to functions as well.
func (*Example) Print() {
	fmt.Println("Example library")
}
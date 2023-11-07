package errors

type Category int

type Error interface {
	error
	Code() Category
}

const (
	MOCK Category = iota
	BAD_REQUEST
	NOT_FOUND
)

type Custom struct {
	code    Category
	message string
}

func (c Custom) Code() Category {
	return c.code
}

func (c Custom) Error() string {
	return c.message
}

type Mock struct{}

func (Mock) Code() Category {
	return MOCK
}

func (Mock) Error() string {
	return "mock"
}

type BadRequest struct{}

func (BadRequest) Code() Category {
	return BAD_REQUEST
}

type NotFound struct{}

func (NotFound) Code() Category {
	return NOT_FOUND
}

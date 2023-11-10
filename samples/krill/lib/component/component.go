package component

type (
	ID string
)

type (
	Store[E any, I comparable] interface {
		Create(entity E, identifier I) error
		Get(identifier I) (E, error)
		Check(identifier I) error
		Delete(identifier I) error
		List() ([]I, error)
	}

	Service[E any, I comparable] interface {
		Create(identifier I, entity E) error
	}
)

package component

type (
	MockService[E any, I comparable] struct {
		OnCreate func(identifier I, entity E) error
	}
	MockStore[E any, I comparable] struct {
		OnCreate func(entity E, identifier I) error
		OnGet    func(identifier I) (E, error)
		OnCheck  func(identifier I) error
		OnDelete func(identifier I) error
		OnList   func() ([]I, error)
	}
)

func (service *MockService[E, I]) Create(identifier I, entity E) error {
	return service.OnCreate(identifier, entity)
}

func (store *MockStore[E, I]) Create(entity E, identifier I) error {
	return store.OnCreate(entity, identifier)
}

func (store *MockStore[E, I]) Get(identifier I) (E, error) {
	return store.OnGet(identifier)
}

func (store *MockStore[E, I]) Check(identifier I) error {
	return store.OnCheck(identifier)
}

func (store *MockStore[E, I]) Delete(identifier I) error {
	return store.OnDelete(identifier)
}

func (store *MockStore[E, I]) List() ([]I, error) {
	return store.OnList()
}

type MockError struct {
	OnError func() string
}

func (err *MockError) Error() string {
	return err.OnError()
}

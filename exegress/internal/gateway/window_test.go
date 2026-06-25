package gateway

import (
	"reflect"
	"testing"
	"time"
)

func TestIPWindowGrace(t *testing.T) {
	t0 := time.Unix(1000, 0)
	w := NewIPWindow(60 * time.Second)

	w.Observe([]string{"1.1.1.1", "2.2.2.2"}, t0)
	if got := w.Active(t0); !reflect.DeepEqual(got, []string{"1.1.1.1", "2.2.2.2"}) {
		t.Fatalf("initial: %v", got)
	}

	// At t0+30s only 1.1.1.1 re-observed; 2.2.2.2 still within grace.
	t1 := t0.Add(30 * time.Second)
	w.Observe([]string{"1.1.1.1"}, t1)
	if got := w.Active(t1); !reflect.DeepEqual(got, []string{"1.1.1.1", "2.2.2.2"}) {
		t.Fatalf("within grace: %v", got)
	}

	// At t0+85s: 2.2.2.2 (last seen t0, 85s ago) is pruned; 1.1.1.1 (last seen
	// t0+30s, 55s ago) is still within the 60s grace.
	t2 := t0.Add(85 * time.Second)
	if got := w.Active(t2); !reflect.DeepEqual(got, []string{"1.1.1.1"}) {
		t.Fatalf("after grace: %v", got)
	}
}

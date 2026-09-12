package main

import (
	"sync"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// commandMemos remembers what this agent did with each command it accepted.
//
// It exists because replay protection and result delivery pull in opposite
// directions. The control plane re-delivers a command whose result it never
// received — which is exactly what happens when the report POST fails, and the
// report POST fails whenever the control plane restarts at the wrong moment, so
// on every deploy. Dropping the redelivery as a duplicate, which is what an
// execute-once set alone does, leaves that command `:delivered` forever.
//
// For a provision that means a VPS stuck in `:provisioning`; for a restore, a
// customer's VPS stuck in `:restoring`, unable to be started, stopped or
// restored again. The command is wedged and nothing retries it.
//
// So the rule is: execute once, report as often as asked. A command that has
// finished re-reports its stored result. One still running says nothing — its
// result is coming.
type commandMemos struct {
	mu    sync.Mutex
	byID  map[string]*commandMemo
	order []string
	max   int
}

type commandMemo struct {
	done   bool
	result transport.CommandResult
}

func newCommandMemos(max int) *commandMemos {
	return &commandMemos{byID: make(map[string]*commandMemo, max), max: max}
}

// accept records that a command has been taken on. It returns the memo of a
// previous acceptance when there is one, and nil when this is the first sight —
// which is the only case the caller should execute.
func (m *commandMemos) accept(id string) *commandMemo {
	if id == "" {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	if existing, ok := m.byID[id]; ok {
		// Return a copy: the caller reads it outside the lock, and the command it
		// belongs to may still be finishing on another goroutine.
		snapshot := *existing
		return &snapshot
	}

	m.byID[id] = &commandMemo{}
	m.order = append(m.order, id)
	// Bounded: a long-lived agent must not grow a map for every command it has
	// ever seen. Evicting the oldest can at worst let a very old redelivery
	// execute twice, which the control plane's own idempotency already covers.
	if len(m.order) > m.max {
		delete(m.byID, m.order[0])
		m.order = m.order[1:]
	}
	return nil
}

// record stores the outcome so a later redelivery can be answered without doing
// the work again.
func (m *commandMemos) record(id string, res transport.CommandResult) {
	if id == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	memo, ok := m.byID[id]
	if !ok {
		// Evicted while the command ran, or never accepted. Nothing to attach to.
		return
	}
	memo.done = true
	memo.result = res
}

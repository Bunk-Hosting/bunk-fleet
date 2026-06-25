// Package provider defines the hypervisor-abstraction contract used by the
// bunk-agent. A concrete provider (Proxmox, Incus, ...) wraps a local
// hypervisor and exposes a small, uniform surface for provisioning,
// deleting, inspecting and reporting capacity of virtual machines.
//
// All implementations MUST be safe for concurrent use and MUST honour the
// supplied context.Context for cancellation and deadlines.
package provider

import "context"

// VMSpec is the desired-state description of a virtual machine that the
// control plane asks the agent to provision. It is hypervisor-agnostic; each
// provider maps these fields onto its native API.
type VMSpec struct {
	// Name is the human-readable / DNS-safe name of the guest.
	Name string `json:"name"`
	// VCPU is the number of virtual CPU cores to allocate.
	VCPU int `json:"vcpu"`
	// RAMMB is the amount of memory to allocate, in megabytes.
	RAMMB int `json:"ram_mb"`
	// DiskGB is the size of the primary disk, in gigabytes.
	DiskGB int `json:"disk_gb"`
	// TemplateID identifies the source template/image to clone from. Its
	// meaning is provider-specific (e.g. a Proxmox VMID template).
	TemplateID int `json:"template_id"`
	// CloudInit holds extra cloud-init key/value pairs (e.g. user, password
	// hash, custom metadata) merged into the generated config.
	CloudInit map[string]string `json:"cloud_init"`
	// SSHKeys is the list of authorized public SSH keys injected via cloud-init.
	SSHKeys []string `json:"ssh_keys"`
	// IPConfig is a provider-native network configuration string
	// (e.g. Proxmox "ip=192.0.2.10/24,gw=192.0.2.1" or "ip=dhcp").
	IPConfig string `json:"ip_config"`
}

// VMStatus is the observed state of a virtual machine.
type VMStatus struct {
	// ID is the provider-native identifier of the guest (e.g. a Proxmox VMID
	// as a string).
	ID string `json:"id"`
	// State is a normalized lifecycle string such as "running", "stopped",
	// "provisioning" or "unknown".
	State string `json:"state"`
	// IP is the primary IPv4 address of the guest, if known/assigned.
	IP string `json:"ip"`
}

// Capacity is a best-effort snapshot of the resources of the underlying node,
// used to build heartbeat reports for the control plane scheduler.
type Capacity struct {
	TotalVCPU   int
	AvailVCPU   int
	TotalRAMMB  int
	AvailRAMMB  int
	TotalDiskGB int
	AvailDiskGB int
}

// Provider is the abstraction over a local hypervisor.
type Provider interface {
	// CreateVM provisions a new guest from the given spec and returns its
	// initial status. It should be effectively idempotent where the backend
	// allows, and must return a non-nil error if provisioning cannot start.
	CreateVM(ctx context.Context, spec VMSpec) (VMStatus, error)

	// DeleteVM stops (if necessary) and destroys the guest identified by id.
	// Deleting a non-existent guest should be treated as success.
	DeleteVM(ctx context.Context, id string) error

	// StatusVM returns the current observed status of the guest identified by id.
	StatusVM(ctx context.Context, id string) (VMStatus, error)

	// FindByName looks up a guest by its (unique) guest name and returns its
	// status. The boolean reports whether a matching guest was found: it is
	// true with a populated VMStatus when a match exists, and false with a zero
	// VMStatus when no guest carries that name. A non-nil error indicates the
	// lookup itself failed (e.g. the backend was unreachable) and the other
	// return values must be ignored.
	//
	// It exists so callers can make provisioning idempotent: before creating a
	// VM they can check whether one with the desired name already exists and, if
	// so, adopt it instead of creating a duplicate.
	FindByName(ctx context.Context, name string) (VMStatus, bool, error)

	// Capacity returns a best-effort snapshot of node resources.
	Capacity(ctx context.Context) (Capacity, error)

	// Name returns the short provider identifier, e.g. "proxmox".
	Name() string
}

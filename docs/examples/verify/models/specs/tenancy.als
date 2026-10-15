// Tenant isolation (issue #130): every object belongs to one tenant, every
// principal acts for one tenant, and access is granted only through a role
// in the object's tenant. The check NoCrossTenantAccess asks the analyser
// for a principal that can reach another tenant's object; finding none
// within the scope is the claim. ShowSharing must have an instance, or the
// model is over-constrained and the check proves nothing.
sig Tenant {}

sig Principal {
  tenant: one Tenant,
  roles: set Role
}

sig Role {
  tenant: one Tenant,
  grants: set Object
}

sig Object {
  owner: one Tenant
}

// A role grants only objects of its own tenant; a principal holds only roles
// of its own tenant.
fact RolesStayInTenant {
  all r: Role | r.grants.owner in r.tenant
  all p: Principal | p.roles.tenant in p.tenant
}

fun canAccess[p: Principal]: set Object {
  p.roles.grants
}

assert NoCrossTenantAccess {
  all p: Principal, o: Object | o in canAccess[p] implies o.owner = p.tenant
}

check NoCrossTenantAccess for 5

pred ShowSharing {
  some disj p1, p2: Principal | p1.tenant = p2.tenant and some canAccess[p1] & canAccess[p2]
  #Tenant > 1
}

run ShowSharing for 4

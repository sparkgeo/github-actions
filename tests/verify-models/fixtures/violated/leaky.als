// Tenancy without the rule that a principal holds only its own tenant's
// roles: NoCrossTenantAccess has a counterexample. Impossible is a run with
// no instance (vacuous), and KnownFlaw documents a counterexample with
// `expect 1`, so it does not fail.
sig Tenant {}
sig Principal { tenant: one Tenant, roles: set Role }
sig Role { tenant: one Tenant, grants: set Object }
sig Object { owner: one Tenant }

fact RolesStayInTenant {
  all r: Role | r.grants.owner in r.tenant
}

fun canAccess[p: Principal]: set Object { p.roles.grants }

assert NoCrossTenantAccess {
  all p: Principal, o: Object | o in canAccess[p] implies o.owner = p.tenant
}

check NoCrossTenantAccess for 4
check KnownFlaw { all p: Principal, o: Object | o in canAccess[p] implies o.owner = p.tenant } for 4 expect 1
run Impossible { some p: Principal | p.tenant != p.tenant } for 3

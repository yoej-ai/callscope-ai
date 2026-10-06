# Database security tests

`0001_rls_foundation.test.sql` is a pgTAP test intended for a local Supabase stack.
It covers owner/member visibility, tenant isolation, membership escalation, profile
isolation, anonymous access, and atomic workspace creation.

Run it after installing Docker and the Supabase CLI:

```bash
supabase start
supabase db reset
supabase test db
```

The test transaction rolls back its fixtures and does not leave test users or
workspace data behind.

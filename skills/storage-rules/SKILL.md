---
name: storage-rules
description: >
  Use when the task involves database schema changes, SQL migrations, RLS policies,
  cloud storage buckets, file system persistence, or data access control.
---

# Storage Rules

## RLS ownership

The storage layer is the SOLE OWNER of Row Level Security (RLS) policies. No other layer should create or modify RLS policies. If another layer needs RLS changes, route the request here.

## Migration discipline

- Write all database migrations as reversible SQL — always include `-- Up` and `-- Down` sections
- **Never drop tables, columns, or delete files without explicit human confirmation**
- Name migrations: `YYYYMMDD_HHMMSS_description.sql`
- Place in the project's migration directory (see TECHSTACK.md)

## Access policy documentation

Document every access policy with a comment explaining the intent. Access rules are hard to audit after the fact — write the reasoning at creation time.

## Domain coverage

- Relational/DB: schema design, migrations, RLS, query performance, index strategy
- Cloud file storage: buckets, signed URLs, public/private access
- Local/disk: file system patterns, naming conventions, retention, backup/restore
- Cross-cutting: data security, encryption at rest/in transit, storage cost optimisation

## Skill composition

`storage-rules` governs all persistence concerns. Backend rules do not override storage ownership of RLS. Both skills may apply on tasks that touch APIs + schema.

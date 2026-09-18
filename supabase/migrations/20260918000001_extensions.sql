-- Migration: 20260918000001_extensions | Purpose: Enable required PostgreSQL extensions for PharmaFlow

-- gen_random_uuid() for uuid primary keys (crypto-backed).
create extension if not exists "pgcrypto";

-- Trigram indexes for fuzzy product/alias search (see later migration that adds the indexes).
create extension if not exists "pg_trgm";

-- NOTE: pgvector is intentionally deferred until Phase 3 (AI embeddings).
-- Do not add it here; column/type usage would be unusable on managed instances
-- where the extension is not enabled.

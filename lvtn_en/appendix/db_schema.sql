-- ============================================================================
-- COMPLETE DATABASE SPECIFICATION
-- LMS for Automatically Generating Micro-Content and Quizzes Using Generative AI
-- Source of Truth: PostgreSQL (31 core tables + 2 implementation extensions)
-- ============================================================================
-- Environment requirements:
--   - PostgreSQL 18+ (native uuidv7() function)
--   - For PostgreSQL 16/17: install the pg_uuidv7 extension instead
--   - Extension pgcrypto for digest/random helpers used by implementation code
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- Surrogate UUID primary keys below use uuidv7() for near-sequential B-Tree
-- insertion. Composite/natural keys remain unchanged.

-- ============================================================================
-- ENUM TYPES (inline CHECK constraints for portability)
-- ============================================================================
-- AI-generated content lifecycle (aligned with the State Machine in 4.11):
--   GENERATED_DRAFT -> REVIEWING -> CHANGES_REQUESTED -> APPROVED
--                                                  |
--                                              PUBLISHED -> UNPUBLISHED -> ARCHIVED

-- ============================================================================
-- SUBSYSTEM 1: IDENTITY AND CANVAS LMS INTEGRATION
-- ============================================================================

-- 1. User mapping between the internal system and Canvas (LTI 1.3)
CREATE TABLE lms_user_mappings (
    internal_user_id UUID PRIMARY KEY DEFAULT uuidv7(),
    lms_type VARCHAR(50) NOT NULL DEFAULT 'canvas',
    lms_sub VARCHAR(255) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    -- This is the user's default role at platform level (admin / instructor / learner).
    -- Per-LTI-context (course) roles are tracked in course_memberships (#3d).
    role VARCHAR(50) NOT NULL CHECK (role IN ('instructor','learner','administrator')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_lms_user UNIQUE (lms_type, lms_sub)
);

-- 2. Courses synchronized from the LMS
CREATE TABLE courses (
    course_id UUID PRIMARY KEY DEFAULT uuidv7(),
    lms_id VARCHAR(100) UNIQUE,
    code VARCHAR(50) NOT NULL UNIQUE,            -- e.g. CO2003
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 3. LTI context reference and custom settings
CREATE TABLE lms_course_ref (
    course_ref_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    lms_context_id VARCHAR(255) NOT NULL,
    lms_custom_settings JSONB DEFAULT '{}'::jsonb,
    synced_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_course_context UNIQUE (course_id, lms_context_id)
);

-- 3b. LTI Resource Links (Deep Linking activities created in Canvas).
--     Each activity points to a card / lesson on our side via custom claims.
CREATE TABLE lti_resource_links (
    resource_link_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_ref_id UUID NOT NULL REFERENCES lms_course_ref(course_ref_id) ON DELETE RESTRICT,
    lms_resource_link_id VARCHAR(255) NOT NULL,   -- as sent by Canvas
    target_kind VARCHAR(30) NOT NULL              -- 'lesson' | 'card' | 'quiz_set' | 'chat' | 'video'
        CHECK (target_kind IN ('lesson','card','quiz_set','chat','video')),
    target_id UUID,                               -- card_id / quiz batch id / segment_id
    custom_claims JSONB DEFAULT '{}'::jsonb,      -- e.g. {"lesson_id":"..."}
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_resource_link UNIQUE (course_ref_id, lms_resource_link_id)
);

-- 3c. LTI Line Items (AGS grade sync). One row per gradable activity.
CREATE TABLE lti_line_items (
    line_item_id UUID PRIMARY KEY DEFAULT uuidv7(),
    resource_link_id UUID NOT NULL REFERENCES lti_resource_links(resource_link_id) ON DELETE RESTRICT,
    lms_line_item_url VARCHAR(512) NOT NULL,      -- AGS endpoint for posting scores
    score_maximum NUMERIC(7,2) NOT NULL DEFAULT 100.00,
    label VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_line_item UNIQUE (resource_link_id)
);

-- 3d. Course memberships (per-LTI-context role).
--     LTI 1.3 sends roles per launch; a user can be Instructor in course A and
--     Learner in course B. This table is the authoritative source for course-scoped
--     authorization, populated/refreshed on every LTI launch.
CREATE TABLE course_memberships (
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    role VARCHAR(30) NOT NULL CHECK (role IN ('instructor','learner','ta','observer')),
    last_seen_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, course_id, role)
);


-- ============================================================================
-- SUBSYSTEM 2: COURSE SYLLABUS AND CDIO ASSESSMENT (CURRICULUM SCHEMA)
-- ============================================================================

-- 4. Chapters
CREATE TABLE chapters (
    chapter_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    sort_order INT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 5. Learning Outcomes (LO) mapped to CDIO -- versioned by academic year
--    Novelty: track LO changes per year (Knowledge Graph evolves)
CREATE TABLE learning_outcomes (
    lo_id UUID PRIMARY KEY DEFAULT uuidv7(),
    chapter_id UUID NOT NULL REFERENCES chapters(chapter_id) ON DELETE RESTRICT,
    code VARCHAR(50) NOT NULL,                   -- L.O.X.Y
    statement_vi TEXT NOT NULL,
    statement_en TEXT,
    bloom_level INT NOT NULL CHECK (bloom_level BETWEEN 1 AND 6),
    cdio_level VARCHAR(5) NOT NULL CHECK (cdio_level IN ('I','II','III')),
    academic_year VARCHAR(10),                   -- e.g. '2024-2025'
    version INT NOT NULL DEFAULT 1,
    is_current BOOLEAN NOT NULL DEFAULT TRUE,    -- only one active version per (chapter, code)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_lo_code_versioned UNIQUE (chapter_id, code, academic_year, version)
);

-- 6. Assessment items
CREATE TABLE assessments (
    assessment_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    max_points NUMERIC(5,2) NOT NULL DEFAULT 100.00,
    sort_order INT NOT NULL,
    type VARCHAR(50) NOT NULL CHECK (type IN ('QUIZ','ASSIGNMENT','FINAL_EXAM','MIDTERM','PROJECT')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 7. LO <-> Assessment weighted mapping
CREATE TABLE lo_assessments (
    lo_id UUID NOT NULL REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    assessment_id UUID NOT NULL REFERENCES assessments(assessment_id) ON DELETE RESTRICT,
    weight NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (weight BETWEEN 0.00 AND 1.00),
    PRIMARY KEY (lo_id, assessment_id)
);


-- ============================================================================
-- SUBSYSTEM 3: DOCUMENTS AND TEXT CHUNKING (DOCUMENT INGESTION)
-- ============================================================================

-- 8. Raw documents
CREATE TABLE documents (
    document_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    file_path VARCHAR(512) NOT NULL,
    mime_type VARCHAR(100),
    checksum VARCHAR(64),                        -- SHA-256 to prevent duplicate uploads
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','UPLOADING','UPLOADED','QUEUED','PARSING','CHUNKING','EMBEDDING','INDEXED','ENRICHING','GENERATED_DRAFT','ERROR')),
    created_by UUID REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 9. Text chunks (high-write; UUIDv7 reduces B-Tree fragmentation)
CREATE TABLE chunks (
    chunk_id UUID PRIMARY KEY DEFAULT uuidv7(),
    document_id UUID NOT NULL REFERENCES documents(document_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,  -- denormalized for RAG filter
    content TEXT NOT NULL,
    heading_path TEXT[],                         -- e.g. {"Chapter 1","Section 1.2"}
    page_number INT,
    sort_order INT NOT NULL,
    language VARCHAR(10) NOT NULL DEFAULT 'vi'   -- mirrored into Qdrant payload
        CHECK (language IN ('vi','en','mixed')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 10. Chunk <-> LO mapping
CREATE TABLE chunk_lo_mappings (
    chunk_id UUID NOT NULL REFERENCES chunks(chunk_id) ON DELETE RESTRICT,
    lo_id UUID NOT NULL REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    confidence NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (confidence BETWEEN 0.00 AND 1.00),
    PRIMARY KEY (chunk_id, lo_id)
);

-- Implementation extension: deterministic concept graph tags for chunks.
-- These two tables are not part of the 31 core DDL tables above/below; they
-- support heading/concept enrichment in the Python pipeline. concepts.id is a
-- stable text slug by design, so it is the one intentional non-UUID extension PK.
CREATE TABLE concepts (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    canonical_name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    domain TEXT,
    category TEXT NOT NULL DEFAULT 'other',
    language TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_concepts_slug ON concepts(slug);

CREATE TABLE chunk_concepts (
    chunk_id UUID NOT NULL REFERENCES chunks(chunk_id) ON DELETE RESTRICT,
    concept_id TEXT NOT NULL REFERENCES concepts(id) ON DELETE CASCADE,
    confidence NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (confidence BETWEEN 0.00 AND 1.00),
    source TEXT NOT NULL DEFAULT 'heading',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (chunk_id, concept_id)
);

CREATE INDEX idx_chunk_concepts_concept_id ON chunk_concepts(concept_id);


-- ============================================================================
-- SUBSYSTEM 4: VIDEO AND MULTIMEDIA SEGMENTATION (VIDEO PIPELINE)
-- ============================================================================

-- 11. Lecture videos
CREATE TABLE videos (
    video_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    file_path VARCHAR(512) NOT NULL,
    is_youtube BOOLEAN DEFAULT FALSE,
    external_url VARCHAR(512),
    language VARCHAR(10) DEFAULT 'vi' CHECK (language IN ('vi','en','mixed')),
    status VARCHAR(50) NOT NULL DEFAULT 'UPLOADING'
        CHECK (status IN ('UPLOADING','UPLOADED','QUEUED','TRANSCRIBING','SEGMENTING','EMBEDDING','INDEXED','ERROR')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 12. Video segments (30-90s clips)
CREATE TABLE video_segments (
    segment_id UUID PRIMARY KEY DEFAULT uuidv7(),
    video_id UUID NOT NULL REFERENCES videos(video_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,  -- denormalized
    start_ms INT NOT NULL,
    end_ms INT NOT NULL,
    clip_url VARCHAR(512),
    thumbnail_url VARCHAR(512),
    title VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CHECK (end_ms > start_ms)
);

-- 13. Timestamped transcript (finer than a segment, 1-n with segment)
CREATE TABLE transcript_segments (
    transcript_id UUID PRIMARY KEY DEFAULT uuidv7(),
    segment_id UUID NOT NULL REFERENCES video_segments(segment_id) ON DELETE RESTRICT,
    text TEXT NOT NULL,
    start_ms INT NOT NULL,
    end_ms INT NOT NULL,
    language VARCHAR(10) DEFAULT 'vi' CHECK (language IN ('vi','en','mixed')),
    deleted_at TIMESTAMP WITH TIME ZONE,
    CHECK (end_ms > start_ms)
);


-- ============================================================================
-- SUBSYSTEM 5: AI MICRO-CONTENT AND QUIZZES (GENERATED CONTENT)
-- ============================================================================
-- Status lifecycle aligned with the State Machine in 4.11

-- 14. Lessons (a curated grouping of cards + quizzes for one Learning Outcome,
--     used as the unit of Deep Linking and the lesson_id surfaced in LTI custom claims)
CREATE TABLE lessons (
    lesson_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    lo_id UUID NOT NULL REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT','PUBLISHED','UNPUBLISHED','ARCHIVED')),
    published_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_lesson_per_lo UNIQUE (course_id, lo_id)
);

-- 15. Lesson Cards
CREATE TABLE lesson_cards (
    card_id UUID PRIMARY KEY DEFAULT uuidv7(),
    lesson_id UUID NOT NULL REFERENCES lessons(lesson_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,  -- denormalized
    lo_id UUID REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    content JSONB NOT NULL,                      -- {key_insight, bullets[]}
    source_chunk_ids UUID[],
    status VARCHAR(50) NOT NULL DEFAULT 'GENERATED_DRAFT'
        CHECK (status IN ('GENERATED_DRAFT','REVIEWING','CHANGES_REQUESTED','APPROVED','PUBLISHED','UNPUBLISHED','ARCHIVED')),
    published_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 16. Card <-> Video Segment attachment
CREATE TABLE card_video_attachments (
    card_id UUID NOT NULL REFERENCES lesson_cards(card_id) ON DELETE RESTRICT,
    segment_id UUID NOT NULL REFERENCES video_segments(segment_id) ON DELETE RESTRICT,
    sort_order INT NOT NULL DEFAULT 1,
    PRIMARY KEY (card_id, segment_id)
);

-- 17. Quiz Items
CREATE TABLE quiz_items (
    quiz_id UUID PRIMARY KEY DEFAULT uuidv7(),
    lesson_id UUID NOT NULL REFERENCES lessons(lesson_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,  -- denormalized
    lo_id UUID REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    -- Four question types matched to FR-SL-03 and US-IN-07:
    type VARCHAR(30) NOT NULL CHECK (type IN ('MCQ_SINGLE','MCQ_MULTI','TRUE_FALSE','FILL_BLANK')),
    question TEXT NOT NULL,
    options JSONB,                               -- MCQ choices or fill-blank slot definitions
    correct_answer JSONB NOT NULL,               -- string for SINGLE/T-F/FILL, array for MULTI
    explanation TEXT,
    bloom_level INT CHECK (bloom_level BETWEEN 1 AND 6),
    source_chunk_ids UUID[],
    status VARCHAR(50) NOT NULL DEFAULT 'GENERATED_DRAFT'
        CHECK (status IN ('GENERATED_DRAFT','REVIEWING','CHANGES_REQUESTED','APPROVED','PUBLISHED','UNPUBLISHED','ARCHIVED')),
    published_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 18. Per-learner flashcard review state (FR-SL-02, US-LE-03)
--     A flashcard is the "flip" presentation of a lesson_card (front=title,
--     back=key_insight). This table stores spaced-repetition state per learner.
CREATE TABLE flashcard_reviews (
    review_id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    card_id UUID NOT NULL REFERENCES lesson_cards(card_id) ON DELETE RESTRICT,
    state VARCHAR(20) NOT NULL DEFAULT 'NEW'
        CHECK (state IN ('NEW','MASTERED','REVIEW_AGAIN')),
    last_seen_at TIMESTAMP WITH TIME ZONE,
    next_due_at TIMESTAMP WITH TIME ZONE,
    review_count INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_user_card UNIQUE (user_id, card_id)
);


-- ============================================================================
-- SUBSYSTEM 6: LEARNING ANALYTICS AND AUDIT LOGS
-- ============================================================================

-- 19. Quiz attempts
--     resource_link_id is filled in only when the attempt is reached via an
--     LTI launch; it provides the key to look up the AGS line_item for grade passback.
CREATE TABLE quiz_attempts (
    attempt_id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    quiz_id UUID NOT NULL REFERENCES quiz_items(quiz_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    resource_link_id UUID REFERENCES lti_resource_links(resource_link_id) ON DELETE RESTRICT,
    score NUMERIC(5,2) NOT NULL,
    chosen_answer JSONB NOT NULL,                -- matches quiz_items.correct_answer JSONB
    is_correct BOOLEAN NOT NULL,
    response_time_ms INT,
    feedback TEXT,
    ags_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (ags_status IN ('NOT_REQUIRED','PENDING','POSTED','FAILED')),
    ags_posted_at TIMESTAMP WITH TIME ZONE,
    attempted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 20. Chat messages (high-write, UUIDv7)
CREATE TABLE chat_messages (
    message_id UUID PRIMARY KEY DEFAULT uuidv7(),
    session_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    course_id UUID REFERENCES courses(course_id) ON DELETE RESTRICT,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user','assistant','system')),
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,          -- citations, tokens
    sent_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 21. Learning events (append-only stream, no soft delete)
CREATE TABLE learning_events (
    event_id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    event_type VARCHAR(100) NOT NULL,            -- VIEW_CARD, READ_DURATION, VIDEO_PLAY, QUIZ_SUBMIT
    target_entity_type VARCHAR(50) NOT NULL,
    target_entity_id UUID NOT NULL,              -- polymorphic, no FK
    duration_sec INT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 22. Review audit logs (append-only, no soft delete)
CREATE TABLE review_audit_logs (
    log_id UUID PRIMARY KEY DEFAULT uuidv7(),
    action VARCHAR(100) NOT NULL,                -- EDIT_CARD, DELETE_QUIZ, PUBLISH_CONTENT
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    performed_by UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    raw_changes JSONB NOT NULL,                  -- {before, after}
    logged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 23. LLM usage logs (high-write audit for cost monitoring, UUIDv7)
--     Each LLM/embedding call is recorded to support AI Cost Monitoring
--     (Section 4.10.4) and to break down spend per user / course / day.
CREATE TABLE llm_usage_logs (
    usage_id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID REFERENCES lms_user_mappings(internal_user_id) ON DELETE SET NULL,
    course_id UUID REFERENCES courses(course_id) ON DELETE SET NULL,
    provider VARCHAR(50) NOT NULL,               -- gemini, openai, bge-m3
    model VARCHAR(100) NOT NULL,                 -- gemini-1.5-pro, gemini-1.5-flash
    use_case VARCHAR(50) NOT NULL,               -- RAG_CHAT, CARD_GEN, QUIZ_GEN, EMBED
    prompt_tokens INT NOT NULL DEFAULT 0,
    completion_tokens INT NOT NULL DEFAULT 0,
    total_tokens INT GENERATED ALWAYS AS (prompt_tokens + completion_tokens) STORED,
    cost_usd NUMERIC(10,6) NOT NULL DEFAULT 0,   -- priced from the provider rate card at call time
    latency_ms INT,
    status VARCHAR(20) NOT NULL CHECK (status IN ('OK','RATE_LIMITED','ERROR')),
    trace_id VARCHAR(64),                        -- OpenTelemetry trace_id for log cross-reference
    called_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 24. Per-user LLM quota state (Section 4.4.5).
--     Tracks daily/monthly consumption to enforce limits at the Rate Limiting layer.
CREATE TABLE user_llm_quota (
    user_id UUID PRIMARY KEY REFERENCES lms_user_mappings(internal_user_id) ON DELETE CASCADE,
    daily_tokens_used INT NOT NULL DEFAULT 0,
    daily_limit INT NOT NULL DEFAULT 100000,     -- 100K tokens/day by default
    monthly_tokens_used INT NOT NULL DEFAULT 0,
    monthly_limit INT NOT NULL DEFAULT 2000000,
    daily_reset_at DATE NOT NULL DEFAULT CURRENT_DATE,
    monthly_reset_at DATE NOT NULL DEFAULT (date_trunc('month', CURRENT_DATE)::DATE),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 25. Per-scope LLM quota (US-AD-02: quota by course or by instructor).
--     scope='course'  -> scope_id = course_id, applies to all generation in that course.
--     scope='instructor' -> scope_id = lms_user_mappings.internal_user_id (instructor's id).
--     Rate Limiting checks the per-user quota AND the relevant scope quota; the
--     stricter wins. Course quota lets admins cap shared courses without per-user setup.
CREATE TABLE scope_llm_quota (
    scope VARCHAR(20) NOT NULL CHECK (scope IN ('course','instructor')),
    scope_id UUID NOT NULL,
    monthly_tokens_used INT NOT NULL DEFAULT 0,
    monthly_limit INT NOT NULL DEFAULT 10000000,
    monthly_reset_at DATE NOT NULL DEFAULT (date_trunc('month', CURRENT_DATE)::DATE),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (scope, scope_id)
);


-- ============================================================================
-- SUBSYSTEM 7: ASYNC OUTBOX, REQUESTS, AND ENGINE CACHE
-- ============================================================================

-- 26. AI content generation requests (Micro-Content / Quiz)
--     Surfaced to the instructor as a single request_id with progress.
--     Workers update status as they consume the corresponding outbox event.
CREATE TABLE content_generation_requests (
    request_id UUID PRIMARY KEY DEFAULT uuidv7(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    requested_by UUID REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    type VARCHAR(20) NOT NULL CHECK (type IN ('card','quiz')),
    scope JSONB NOT NULL,                        -- {chapter_id, lo_id, count, bloom, difficulty}
    status VARCHAR(50) NOT NULL DEFAULT 'QUEUED'
        CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED')),
    generated_count INT NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 27. Outbox events (synced to Neo4j via the poller daemon in core-api;
--     Qdrant upserts happen inline in the worker job and do NOT use Outbox)
CREATE TABLE outbox_events (
    event_id UUID PRIMARY KEY DEFAULT uuidv7(),
    event_type VARCHAR(100) NOT NULL,            -- CARD_PUBLISHED, CHUNK_INDEXED, LO_CREATED, ...
    aggregate_type VARCHAR(50),                  -- 'lesson_card','chunk','learning_outcome', ...
    aggregate_id UUID,
    payload JSONB NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','PROCESSING','PROCESSED','FAILED','DEAD_LETTER')),
    retry_count INT DEFAULT 0,
    last_error TEXT,                             -- debug message on FAILED
    occurred_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP WITH TIME ZONE        -- for latency monitoring
);

-- 28. YouTube search cache
CREATE TABLE youtube_search_cache (
    query_hash VARCHAR(64) PRIMARY KEY,          -- SHA-256
    search_query TEXT NOT NULL,
    search_results JSONB NOT NULL,
    cached_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE          -- explicit TTL for the cleanup job
);


-- ============================================================================
-- INDEXES - QUERY OPTIMIZATION
-- ============================================================================

-- LMS / Course
CREATE INDEX idx_lms_mapping ON lms_user_mappings(lms_type, lms_sub) WHERE deleted_at IS NULL;
CREATE INDEX idx_course_lms ON courses(lms_id) WHERE deleted_at IS NULL;

-- Curriculum
CREATE INDEX idx_chapters_course ON chapters(course_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX idx_lo_chapter ON learning_outcomes(chapter_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_lo_current ON learning_outcomes(chapter_id, code) WHERE is_current = TRUE AND deleted_at IS NULL;

-- Document / Chunk
CREATE INDEX idx_chunks_document ON chunks(document_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX idx_chunks_course ON chunks(course_id) WHERE deleted_at IS NULL;   -- primary RAG filter
CREATE INDEX idx_chunk_lo_ref ON chunk_lo_mappings(lo_id);
CREATE INDEX idx_documents_course_status ON documents(course_id, status) WHERE deleted_at IS NULL;

-- Video
CREATE INDEX idx_video_course ON videos(course_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_segments_video ON video_segments(video_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_segments_course ON video_segments(course_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_transcript_segment ON transcript_segments(segment_id) WHERE deleted_at IS NULL;

-- Generated content (indexed only for PUBLISHED or REVIEWING states)
CREATE INDEX idx_lesson_cards_lo_published
    ON lesson_cards(lo_id, course_id)
    WHERE status = 'PUBLISHED' AND deleted_at IS NULL;
CREATE INDEX idx_lesson_cards_review
    ON lesson_cards(course_id, updated_at)
    WHERE status IN ('GENERATED_DRAFT','REVIEWING','CHANGES_REQUESTED') AND deleted_at IS NULL;
CREATE INDEX idx_quiz_items_lo_published
    ON quiz_items(lo_id, course_id)
    WHERE status = 'PUBLISHED' AND deleted_at IS NULL;
CREATE INDEX idx_quiz_items_review
    ON quiz_items(course_id, updated_at)
    WHERE status IN ('GENERATED_DRAFT','REVIEWING','CHANGES_REQUESTED') AND deleted_at IS NULL;

-- Analytics
CREATE INDEX idx_chat_session ON chat_messages(session_id, sent_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_chat_user_course ON chat_messages(user_id, course_id, sent_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_event_user_course ON learning_events(user_id, course_id, event_type);
CREATE INDEX idx_event_target ON learning_events(target_entity_type, target_entity_id);
CREATE INDEX idx_quiz_attempts_user_lo ON quiz_attempts(user_id, quiz_id) WHERE deleted_at IS NULL;

-- Outbox poller (partial index, critical for the daemon scan)
CREATE INDEX idx_outbox_pending_poller ON outbox_events(occurred_at) WHERE status = 'PENDING';
CREATE INDEX idx_outbox_failed ON outbox_events(occurred_at) WHERE status = 'FAILED';


-- ============================================================================
-- BUSINESS VIEWS
-- ============================================================================

-- Lists the current LO version for each chapter
CREATE OR REPLACE VIEW v_current_learning_outcomes AS
SELECT lo.*, ch.course_id, ch.title AS chapter_title
FROM learning_outcomes lo
JOIN chapters ch ON ch.chapter_id = lo.chapter_id
WHERE lo.is_current = TRUE
  AND lo.deleted_at IS NULL
  AND ch.deleted_at IS NULL;

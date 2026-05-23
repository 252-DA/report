-- ============================================================================
-- ĐẶC TẢ CƠ SỞ DỮ LIỆU TOÀN DIỆN
-- Hệ thống LMS tự động tạo Micro-Content & Quiz bằng Generative AI
-- Source of Truth: PostgreSQL (24 bảng)
-- ============================================================================
-- Yêu cầu môi trường:
--   - PostgreSQL 16+ (khuyến nghị 17+ để dùng uuidv7() native ở PG 18)
--   - Extension pg_uuidv7 (cho PG <= 17). Nếu PG 18+ thì dùng uuidv7() built-in.
--   - Extension pgcrypto (fallback cho gen_random_uuid khi không có pg_uuidv7)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- CREATE EXTENSION IF NOT EXISTS pg_uuidv7;
-- Nếu chưa cài pg_uuidv7, dùng wrapper sau (UUIDv4 fallback) khi tạo bảng:
--   DEFAULT gen_random_uuid()
-- Khi triển khai production, thay tất cả default sang:
--   DEFAULT uuidv7()
-- để tận dụng B-Tree index sắp xếp tuần tự theo timestamp (nguyên tắc 4.1.2 #5).

-- ============================================================================
-- ENUM TYPES (CHECK constraints inline cho tính di động)
-- ============================================================================
-- Vòng đời học liệu sinh bởi AI (đồng bộ với State Machine ở 4.11)
--   GENERATED_DRAFT → REVIEWING → CHANGES_REQUESTED → APPROVED
--                                                  ↓
--                                              PUBLISHED → UNPUBLISHED → ARCHIVED

-- ============================================================================
-- PHÂN HỆ 1: DANH TÍNH & TÍCH HỢP CANVAS LMS (LMS INTEGRATION)
-- ============================================================================

-- 1. Ánh xạ người dùng giữa hệ thống nội bộ và Canvas (LTI 1.3)
CREATE TABLE lms_user_mappings (
    internal_user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lms_type VARCHAR(50) NOT NULL DEFAULT 'canvas',
    lms_sub VARCHAR(255) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL CHECK (role IN ('instructor','learner','administrator')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_lms_user UNIQUE (lms_type, lms_sub)
);

-- 2. Khóa học đồng bộ từ LMS
CREATE TABLE courses (
    course_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lms_id VARCHAR(100) UNIQUE,
    code VARCHAR(50) NOT NULL UNIQUE,            -- Ví dụ: CO2003
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 3. Tham chiếu ngữ cảnh và cấu hình tùy biến LTI
CREATE TABLE lms_course_ref (
    course_ref_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    lms_context_id VARCHAR(255) NOT NULL,
    lms_custom_settings JSONB DEFAULT '{}'::jsonb,
    synced_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_course_context UNIQUE (course_id, lms_context_id)
);


-- ============================================================================
-- PHÂN HỆ 2: ĐỀ CƯƠNG MÔN HỌC & ĐÁNH GIÁ CDIO (CURRICULUM SCHEMA)
-- ============================================================================

-- 4. Chương học
CREATE TABLE chapters (
    chapter_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    sort_order INT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 5. Learning Outcomes (LO) ánh xạ theo CDIO -- có versioning theo năm học
--    Novelty: track LO thay đổi theo năm (Knowledge Graph evolves)
CREATE TABLE learning_outcomes (
    lo_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chapter_id UUID NOT NULL REFERENCES chapters(chapter_id) ON DELETE RESTRICT,
    code VARCHAR(50) NOT NULL,                   -- L.O.X.Y
    statement_vi TEXT NOT NULL,
    statement_en TEXT,
    bloom_level INT NOT NULL CHECK (bloom_level BETWEEN 1 AND 6),
    cdio_level VARCHAR(5) NOT NULL CHECK (cdio_level IN ('I','II','III')),
    academic_year VARCHAR(10),                   -- VD: '2024-2025'
    version INT NOT NULL DEFAULT 1,
    is_current BOOLEAN NOT NULL DEFAULT TRUE,    -- chỉ 1 version active per (chapter, code)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_lo_code_versioned UNIQUE (chapter_id, code, academic_year, version)
);

-- 6. Đầu điểm đánh giá
CREATE TABLE assessments (
    assessment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    max_points NUMERIC(5,2) NOT NULL DEFAULT 100.00,
    sort_order INT NOT NULL,
    type VARCHAR(50) NOT NULL CHECK (type IN ('QUIZ','ASSIGNMENT','FINAL_EXAM','MIDTERM','PROJECT')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 7. Ánh xạ trọng số LO ↔ Assessment
CREATE TABLE lo_assessments (
    lo_id UUID NOT NULL REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    assessment_id UUID NOT NULL REFERENCES assessments(assessment_id) ON DELETE RESTRICT,
    weight NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (weight BETWEEN 0.00 AND 1.00),
    PRIMARY KEY (lo_id, assessment_id)
);


-- ============================================================================
-- PHÂN HỆ 3: TÀI LIỆU VÀ PHÂN ĐOẠN VĂN BẢN (DOCUMENT INGESTION)
-- ============================================================================

-- 8. Tài liệu thô
CREATE TABLE documents (
    document_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    file_path VARCHAR(512) NOT NULL,
    mime_type VARCHAR(100),
    checksum VARCHAR(64),                        -- SHA-256 chống upload trùng
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','UPLOADING','UPLOADED','QUEUED','PARSING','CHUNKING','EMBEDDING','INDEXED','ENRICHING','GENERATED_DRAFT','ERROR')),
    created_by UUID REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 9. Chunks văn bản (high-write, dùng UUIDv7 để giảm fragmentation B-Tree)
CREATE TABLE chunks (
    chunk_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES documents(document_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,  -- denormalized cho RAG filter
    content TEXT NOT NULL,
    heading_path TEXT[],                         -- {"Chương 1","Mục 1.2"}
    page_number INT,
    sort_order INT NOT NULL,
    language VARCHAR(10) NOT NULL DEFAULT 'vi'   -- sync với Qdrant payload
        CHECK (language IN ('vi','en','mixed')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 10. Chunk ↔ LO mapping
CREATE TABLE chunk_lo_mappings (
    chunk_id UUID NOT NULL REFERENCES chunks(chunk_id) ON DELETE RESTRICT,
    lo_id UUID NOT NULL REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    confidence NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (confidence BETWEEN 0.00 AND 1.00),
    PRIMARY KEY (chunk_id, lo_id)
);


-- ============================================================================
-- PHÂN HỆ 4: VIDEO VÀ PHÂN TÁCH ĐA PHƯƠNG TIỆN (VIDEO PIPELINE)
-- ============================================================================

-- 11. Video bài giảng
CREATE TABLE videos (
    video_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    file_path VARCHAR(512) NOT NULL,
    is_youtube BOOLEAN DEFAULT FALSE,
    external_url VARCHAR(512),
    language VARCHAR(10) DEFAULT 'vi' CHECK (language IN ('vi','en','mixed')),
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','PROCESSING','TRANSCRIBED','SEGMENTED','INDEXED','ERROR')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 12. Phân đoạn video (clip cắt 30-90s)
CREATE TABLE video_segments (
    segment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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

-- 13. Transcript có timestamp (granularity nhỏ hơn segment, 1-n với segment)
CREATE TABLE transcript_segments (
    transcript_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    segment_id UUID NOT NULL REFERENCES video_segments(segment_id) ON DELETE RESTRICT,
    text TEXT NOT NULL,
    start_ms INT NOT NULL,
    end_ms INT NOT NULL,
    language VARCHAR(10) DEFAULT 'vi' CHECK (language IN ('vi','en','mixed')),
    deleted_at TIMESTAMP WITH TIME ZONE,
    CHECK (end_ms > start_ms)
);


-- ============================================================================
-- PHÂN HỆ 5: HỌC LIỆU VI MÔ AI & QUIZ (GENERATED CONTENT)
-- ============================================================================
-- Vòng đời status thống nhất với State Machine ở 4.11

-- 14. Lesson Cards
CREATE TABLE lesson_cards (
    card_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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

-- 15. Card ↔ Video Segment attachment
CREATE TABLE card_video_attachments (
    card_id UUID NOT NULL REFERENCES lesson_cards(card_id) ON DELETE RESTRICT,
    segment_id UUID NOT NULL REFERENCES video_segments(segment_id) ON DELETE RESTRICT,
    sort_order INT NOT NULL DEFAULT 1,
    PRIMARY KEY (card_id, segment_id)
);

-- 16. Quiz Items
CREATE TABLE quiz_items (
    quiz_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,  -- denormalized
    lo_id UUID REFERENCES learning_outcomes(lo_id) ON DELETE RESTRICT,
    type VARCHAR(30) NOT NULL CHECK (type IN ('MCQ','SHORT_ANSWER','TRUE_FALSE')),
    question TEXT NOT NULL,
    options JSONB,                               -- MCQ choices
    correct_answer TEXT NOT NULL,
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


-- ============================================================================
-- PHÂN HỆ 6: PHÂN TÍCH HỌC TẬP & NHẬT KÝ KIỂM DUYỆT (ANALYTICS & AUDIT)
-- ============================================================================

-- 17. Quiz attempts
CREATE TABLE quiz_attempts (
    attempt_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    quiz_id UUID NOT NULL REFERENCES quiz_items(quiz_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    score NUMERIC(5,2) NOT NULL,
    chosen_answer TEXT NOT NULL,
    is_correct BOOLEAN NOT NULL,
    response_time_ms INT,
    feedback TEXT,
    attempted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 18. Chat messages (high-write, UUIDv7)
CREATE TABLE chat_messages (
    message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    course_id UUID REFERENCES courses(course_id) ON DELETE RESTRICT,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user','assistant','system')),
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,          -- citations, tokens
    sent_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 19. Learning events (append-only stream, không soft delete)
CREATE TABLE learning_events (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    course_id UUID NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    event_type VARCHAR(100) NOT NULL,            -- VIEW_CARD, READ_DURATION, VIDEO_PLAY, QUIZ_SUBMIT
    target_entity_type VARCHAR(50) NOT NULL,
    target_entity_id UUID NOT NULL,              -- polymorphic, no FK
    duration_sec INT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 20. Review audit logs (append-only, không soft delete)
CREATE TABLE review_audit_logs (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action VARCHAR(100) NOT NULL,                -- EDIT_CARD, DELETE_QUIZ, PUBLISH_CONTENT
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    performed_by UUID NOT NULL REFERENCES lms_user_mappings(internal_user_id) ON DELETE RESTRICT,
    raw_changes JSONB NOT NULL,                  -- {before, after}
    logged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 21. LLM usage logs (high-write audit cho cost monitoring, UUIDv7)
--     Mỗi lượt gọi LLM/embedding được ghi nhận để hỗ trợ AI Cost Monitoring
--     (mục 4.10.4) và breakdown chi phí per-user/per-course/per-day.
CREATE TABLE llm_usage_logs (
    usage_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES lms_user_mappings(internal_user_id) ON DELETE SET NULL,
    course_id UUID REFERENCES courses(course_id) ON DELETE SET NULL,
    provider VARCHAR(50) NOT NULL,               -- gemini, openai, bge-m3
    model VARCHAR(100) NOT NULL,                 -- gemini-1.5-pro, gemini-1.5-flash
    use_case VARCHAR(50) NOT NULL,               -- RAG_CHAT, CARD_GEN, QUIZ_GEN, EMBED
    prompt_tokens INT NOT NULL DEFAULT 0,
    completion_tokens INT NOT NULL DEFAULT 0,
    total_tokens INT GENERATED ALWAYS AS (prompt_tokens + completion_tokens) STORED,
    cost_usd NUMERIC(10,6) NOT NULL DEFAULT 0,   -- tính theo bảng giá provider tại thời điểm gọi
    latency_ms INT,
    status VARCHAR(20) NOT NULL CHECK (status IN ('OK','RATE_LIMITED','ERROR')),
    trace_id VARCHAR(64),                        -- OpenTelemetry trace_id để cross-reference log
    called_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 22. User LLM quota (per-user rate/quota state, mục 4.4.5)
--     Track tiêu thụ daily/monthly để enforce limit ở Rate Limiting layer.
CREATE TABLE user_llm_quota (
    user_id UUID PRIMARY KEY REFERENCES lms_user_mappings(internal_user_id) ON DELETE CASCADE,
    daily_tokens_used INT NOT NULL DEFAULT 0,
    daily_limit INT NOT NULL DEFAULT 100000,     -- 100K token/ngày mặc định
    monthly_tokens_used INT NOT NULL DEFAULT 0,
    monthly_limit INT NOT NULL DEFAULT 2000000,
    daily_reset_at DATE NOT NULL DEFAULT CURRENT_DATE,
    monthly_reset_at DATE NOT NULL DEFAULT (date_trunc('month', CURRENT_DATE)::DATE),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================================
-- PHÂN HỆ 7: OUTBOX & BỘ ĐỆM (ASYNC OUTBOX & ENGINE CACHE)
-- ============================================================================

-- 21. Outbox events (đồng bộ sang Neo4j/Qdrant qua poller daemon)
CREATE TABLE outbox_events (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type VARCHAR(100) NOT NULL,            -- CARD_PUBLISHED, CHUNK_INDEXED, LO_CREATED, ...
    aggregate_type VARCHAR(50),                  -- 'lesson_card','chunk','learning_outcome', ...
    aggregate_id UUID,
    payload JSONB NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','PROCESSING','PROCESSED','FAILED','DEAD_LETTER')),
    retry_count INT DEFAULT 0,
    last_error TEXT,                             -- debug khi FAILED
    occurred_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP WITH TIME ZONE        -- để monitoring latency
);

-- 22. YouTube search cache
CREATE TABLE youtube_search_cache (
    query_hash VARCHAR(64) PRIMARY KEY,          -- SHA-256
    search_query TEXT NOT NULL,
    search_results JSONB NOT NULL,
    cached_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE          -- TTL explicit để cleanup job
);


-- ============================================================================
-- INDEXES — TỐI ƯU HÓA TRUY VẤN
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
CREATE INDEX idx_chunks_course ON chunks(course_id) WHERE deleted_at IS NULL;   -- RAG filter chính
CREATE INDEX idx_chunk_lo_ref ON chunk_lo_mappings(lo_id);
CREATE INDEX idx_documents_course_status ON documents(course_id, status) WHERE deleted_at IS NULL;

-- Video
CREATE INDEX idx_video_course ON videos(course_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_segments_video ON video_segments(video_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_segments_course ON video_segments(course_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_transcript_segment ON transcript_segments(segment_id) WHERE deleted_at IS NULL;

-- Generated content (chỉ index khi đã publish hoặc chờ review)
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

-- Outbox poller (partial index quan trọng cho daemon scan)
CREATE INDEX idx_outbox_pending_poller ON outbox_events(occurred_at) WHERE status = 'PENDING';
CREATE INDEX idx_outbox_failed ON outbox_events(occurred_at) WHERE status = 'FAILED';


-- ============================================================================
-- VIEWS HỖ TRỢ NGHIỆP VỤ
-- ============================================================================

-- View liệt kê LO version hiện hành cho mỗi chapter
CREATE OR REPLACE VIEW v_current_learning_outcomes AS
SELECT lo.*, ch.course_id, ch.title AS chapter_title
FROM learning_outcomes lo
JOIN chapters ch ON ch.chapter_id = lo.chapter_id
WHERE lo.is_current = TRUE
  AND lo.deleted_at IS NULL
  AND ch.deleted_at IS NULL;


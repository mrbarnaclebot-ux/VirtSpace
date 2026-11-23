ALTER TABLE "captures" ADD COLUMN "bundle_bytes" bigint;--> statement-breakpoint
ALTER TABLE "credit_events" ADD COLUMN "provider" text DEFAULT 'worldlabs' NOT NULL;--> statement-breakpoint
ALTER TABLE "worlds" ADD COLUMN "capture_type" text DEFAULT 'pano' NOT NULL;--> statement-breakpoint
ALTER TABLE "worlds" ADD COLUMN "floorplan_url" text;
# Catalog service capability coverage

LensWorks-owned catalog (upstream provenance `f4f8d3f12acc77fe5632720702c52a7cfefb5b58`); story `sc-24658`. 249 reachable request/result/config/core types and 611 enum variants; 172 commands and 358 input enum choices. Source coverage is not native acceptance.

The matrix contains 172 command rows, 186 nested input choice rows, 761 associated/struct field rows and 6 public original/render identity seams. Every row maps to a concrete fixture profile. All execution is planned/unrun unless exact evidence appears in the JSON execution ledger.

The JSON contains the complete field/type/serde/import graph, all source hashes, all capability rows and 358 full Request specimens. Its 755 standalone specimens cover serialized enum variants and every nongeneric serialized struct, with populated vectors/options and concrete generic Page rows/cursors. Workbench Rows projects public lightroom::plan::Cell, retained as an explicit result root. Specimens establish serialization shape only; real session/job/guard/token/revision/digest/path values must come from preceding successful lifecycle replies, and specimen strings grant no authority.

## Public request and typed result matrix

| Source type / command | Typed successful result | Lifecycle fixture | Status |
| --- | --- | --- | --- |
| `application::copy::Request::Begin` | `application::dto::Response::{EditCopy}; application::copy::Response::{Job}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Append` | `application::dto::Response::{EditCopy}; application::copy::Response::{Job}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Seal` | `application::dto::Response::{EditCopy}; application::copy::Response::{Job}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Run` | `application::dto::Response::{EditCopy}; application::copy::Response::{Operation}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Status` | `application::dto::Response::{EditCopy}; application::copy::Response::{Operation}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Cancel` | `application::dto::Response::{EditCopy}; application::copy::Response::{Operation, Job}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Job` | `application::dto::Response::{EditCopy}; application::copy::Response::{Job}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Jobs` | `application::dto::Response::{EditCopy}; application::copy::Response::{Jobs}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Items` | `application::dto::Response::{EditCopy}; application::copy::Response::{Items}` | `adjustment-transfer` | planned_unrun |
| `application::copy::Request::Inspect` | `application::dto::Response::{EditCopy}; application::copy::Response::{Inspection}` | `adjustment-transfer` | planned_unrun |
| `application::dto::Request::PreviewSettings` | `application::dto::Response::{PreviewSettings}` | `preview-policy-relocation` | planned_unrun |
| `application::dto::Request::LightroomMigration` | `application::dto::Response::{LightroomMigration}` | `guarded-migration` | planned_unrun |
| `application::dto::Request::Lightroom` | `application::dto::Response::{Lightroom}` | `workbench-input-review` | planned_unrun |
| `application::dto::Request::Export` | `application::dto::Response::{Export}` | `export-staging-recovery` | planned_unrun |
| `application::dto::Request::EditCopy` | `application::dto::Response::{EditCopy}` | `adjustment-transfer` | planned_unrun |
| `application::dto::Request::Relink` | `application::dto::Response::{Relink}` | `relink-review-identity` | planned_unrun |
| `application::dto::Request::OpenExisting` | `application::dto::Response::{Status}` | `catalog-open-close` | planned_unrun |
| `application::dto::Request::Create` | `application::dto::Response::{Status}` | `catalog-open-close` | planned_unrun |
| `application::dto::Request::Status` | `application::dto::Response::{Status}` | `catalog-open-close` | planned_unrun |
| `application::dto::Request::Close` | `application::dto::Response::{Status}` | `catalog-open-close` | planned_unrun |
| `application::dto::Request::ImportStart` | `application::dto::Response::{Import}` | `import-resume` | planned_unrun |
| `application::dto::Request::ImportResume` | `application::dto::Response::{Import}` | `import-resume` | planned_unrun |
| `application::dto::Request::ImportStatus` | `application::dto::Response::{Import}` | `import-resume` | planned_unrun |
| `application::dto::Request::ImportCancel` | `application::dto::Response::{Import}` | `import-resume` | planned_unrun |
| `application::dto::Request::BackupCreate` | `application::dto::Response::{Backup}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::BackupInspect` | `application::dto::Response::{Backup}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::BackupRestore` | `application::dto::Response::{Backup}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::BackupStatus` | `application::dto::Response::{Backup}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::BackupCancel` | `application::dto::Response::{Backup}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::RestoreStatus` | `application::dto::Response::{Restore}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::ResumeRestoredJobs` | `application::dto::Response::{Restore}` | `backup-restore-held-jobs` | planned_unrun |
| `application::dto::Request::Metadata` | `application::dto::Response::{Metadata}` | `metadata-resolution` | planned_unrun |
| `application::dto::Request::MetadataWrite` | `application::dto::Response::{MetadataWrite}` | `metadata-write-recovery` | planned_unrun |
| `application::dto::Request::Organization` | `application::dto::Response::{Organization}` | `organization-revisions` | planned_unrun |
| `application::dto::Request::Folders` | `application::dto::Response::{Folders}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Images` | `application::dto::Response::{Images}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Search` | `application::dto::Response::{Images}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Image` | `application::dto::Response::{Image}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Variant` | `application::dto::Response::{Variant}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Variants` | `application::dto::Response::{Variants}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::CreateVariant` | `application::dto::Response::{Variant}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::SaveRecipe` | `application::dto::Response::{Variant}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Undo` | `application::dto::Response::{Variant}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Redo` | `application::dto::Response::{Variant}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::History` | `application::dto::Response::{History}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Cull` | `application::dto::Response::{Culled}` | `browse-edit-history` | planned_unrun |
| `application::dto::Request::Preview` | `application::dto::Response::{Preview}` | `preview-generation-bytes` | planned_unrun |
| `application::dto::Request::PreviewStatus` | `application::dto::Response::{Preview}` | `preview-generation-bytes` | planned_unrun |
| `application::dto::Request::ReleaseViewport` | `application::dto::Response::{Status}` | `preview-generation-bytes` | planned_unrun |
| `application::dto::Request::CancelPreview` | `application::dto::Response::{Preview}` | `preview-generation-bytes` | planned_unrun |
| `application::exports::dto::Request::Options` | `application::dto::Response::{Export}; application::exports::dto::Response::{Options}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Profile` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::ProfileRelease` | `application::dto::Response::{Export}; application::exports::dto::Response::{Released}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Begin` | `application::dto::Response::{Export}; application::exports::dto::Response::{Job}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Paths` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Destinations` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::DestinationRows` | `application::dto::Response::{Export}; application::exports::dto::Response::{Destinations}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::ResultRelease` | `application::dto::Response::{Export}; application::exports::dto::Response::{Released}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Append` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Seal` | `application::dto::Response::{Export}; application::exports::dto::Response::{Job}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Job` | `application::dto::Response::{Export}; application::exports::dto::Response::{Job}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Jobs` | `application::dto::Response::{Export}; application::exports::dto::Response::{Jobs}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Items` | `application::dto::Response::{Export}; application::exports::dto::Response::{Items}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Plan` | `application::dto::Response::{Export}; application::exports::dto::Response::{Plan}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::PlanChunk` | `application::dto::Response::{Export}; application::exports::dto::Response::{PlanChunk}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Run` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Status` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Cancel` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation, Job}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Yield` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Recover` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::RetrySeal` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::exports::dto::Request::Restore` | `application::dto::Response::{Export}; application::exports::dto::Response::{Operation}` | `export-staging-recovery` | planned_unrun |
| `application::lightroom_bridge::wire::Request::SealedDocument` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{SealedDocument}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::ArtifactPreparation` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{ArtifactPreparation}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Options` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Options}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Open` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Status}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Status` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Status}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Action` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Status}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Read` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Status}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Cancel` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Status}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Close` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Status}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::Result` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Result}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::InputBegin` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Input}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::InputAppend` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Input}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::InputFinish` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Input}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::InputDiscard` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Input}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_bridge::wire::Request::InputStatus` | `application::dto::Response::{Lightroom}; application::lightroom_bridge::wire::Response::{Input}` | `workbench-input-review` | planned_unrun |
| `application::lightroom_migration::Request::Begin` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::Upload` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::Finish` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::Act` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::Status` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::Cancel` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status, Discarded}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::RetryDrain` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Status}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::ResultPage` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Page}` | `guarded-migration` | planned_unrun |
| `application::lightroom_migration::Request::Discard` | `application::dto::Response::{LightroomMigration}; application::lightroom_migration::Response::{Discarded}` | `guarded-migration` | planned_unrun |
| `application::metadata::Request::Identity` | `application::dto::Response::{Metadata}; application::metadata::Response::{Identity}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Fields` | `application::dto::Response::{Metadata}; application::metadata::Response::{Fields}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Candidates` | `application::dto::Response::{Metadata}; application::metadata::Response::{Candidates}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Sources` | `application::dto::Response::{Metadata}; application::metadata::Response::{Sources}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Observations` | `application::dto::Response::{Metadata}; application::metadata::Response::{Observations}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Models` | `application::dto::Response::{Metadata}; application::metadata::Response::{Models}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Packets` | `application::dto::Response::{Metadata}; application::metadata::Response::{Packets}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Decisions` | `application::dto::Response::{Metadata}; application::metadata::Response::{Decisions}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::FileInstances` | `application::dto::Response::{Metadata}; application::metadata::Response::{FileInstances}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::Resolve` | `application::dto::Response::{Metadata}; application::metadata::Response::{Changed}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::TextChunk` | `application::dto::Response::{Metadata}; application::metadata::Response::{Chunk}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::BlobChunk` | `application::dto::Response::{Metadata}; application::metadata::Response::{Chunk}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::ImportHistory` | `application::dto::Response::{Metadata}; application::metadata::Response::{ImportHistory}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::ImportColumns` | `application::dto::Response::{Metadata}; application::metadata::Response::{ImportColumns}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::ImportFields` | `application::dto::Response::{Metadata}; application::metadata::Response::{ImportFields}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::ImportChunk` | `application::dto::Response::{Metadata}; application::metadata::Response::{Chunk}` | `metadata-resolution` | planned_unrun |
| `application::metadata::Request::AdobeProperties` | `application::dto::Response::{Metadata}; application::metadata::Response::{AdobeProperties}` | `metadata-resolution` | planned_unrun |
| `application::metadata_write::Request::Options` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Options}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Status` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Status}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Cancel` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Status}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Start` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Admitted}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::InputStatus` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Input}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Receipt` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Receipt}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Review` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Review}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::ReviewFields` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{ReviewFields}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Chunk` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Chunk}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Plans` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Plans}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::Plan` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{Plan}` | `metadata-write-recovery` | planned_unrun |
| `application::metadata_write::Request::RecoveryEntries` | `application::dto::Response::{MetadataWrite}; application::metadata_write::Response::{RecoveryEntries}` | `metadata-write-recovery` | planned_unrun |
| `application::organization::Request::Keywords` | `application::dto::Response::{Organization}; application::organization::Response::{Keywords}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::CreateKeyword` | `application::dto::Response::{Organization}; application::organization::Response::{KeywordCreated}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::DeleteKeyword` | `application::dto::Response::{Organization}; application::organization::Response::{Acknowledged}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Synonyms` | `application::dto::Response::{Organization}; application::organization::Response::{Synonyms}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::AddSynonym` | `application::dto::Response::{Organization}; application::organization::Response::{Acknowledged}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Collections` | `application::dto::Response::{Organization}; application::organization::Response::{Collections}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Collection` | `application::dto::Response::{Organization}; application::organization::Response::{Collection}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::CreateCollection` | `application::dto::Response::{Organization}; application::organization::Response::{CollectionCreated}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::RenameCollection` | `application::dto::Response::{Organization}; application::organization::Response::{Acknowledged}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::DeleteCollection` | `application::dto::Response::{Organization}; application::organization::Response::{Acknowledged}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Placement` | `application::dto::Response::{Organization}; application::organization::Response::{Placement}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::PlaceCollection` | `application::dto::Response::{Organization}; application::organization::Response::{Acknowledged}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Members` | `application::dto::Response::{Organization}; application::organization::Response::{Members}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Identity` | `application::dto::Response::{Organization}; application::organization::Response::{Identity}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::SetMember` | `application::dto::Response::{Organization}; application::organization::Response::{Changed}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Membership` | `application::dto::Response::{Organization}; application::organization::Response::{Membership}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Apply` | `application::dto::Response::{Organization}; application::organization::Response::{Changed}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Begin` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Append` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Seal` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Step` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Cancel` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Job` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Jobs` | `application::dto::Response::{Organization}; application::organization::Response::{Jobs}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Items` | `application::dto::Response::{Organization}; application::organization::Response::{Items}` | `organization-revisions` | planned_unrun |
| `application::organization::Request::Review` | `application::dto::Response::{Organization}; application::organization::Response::{Job}` | `organization-revisions` | planned_unrun |
| `application::preview_settings::Request::Status` | `application::dto::Response::{PreviewSettings}; application::preview_settings::Status` | `preview-policy-relocation` | planned_unrun |
| `application::preview_settings::Request::SetBudgets` | `application::dto::Response::{PreviewSettings}; application::preview_settings::Status` | `preview-policy-relocation` | planned_unrun |
| `application::preview_settings::Request::BeginOriginalRootReview` | `application::dto::Response::{PreviewSettings}; application::preview_settings::Status` | `preview-policy-relocation` | planned_unrun |
| `application::preview_settings::Request::StepOriginalRootReview` | `application::dto::Response::{PreviewSettings}; application::preview_settings::Status` | `preview-policy-relocation` | planned_unrun |
| `application::preview_settings::Request::BeginRelocation` | `application::dto::Response::{PreviewSettings}; application::preview_settings::Status` | `preview-policy-relocation` | planned_unrun |
| `application::preview_settings::Request::StepRelocation` | `application::dto::Response::{PreviewSettings}; application::preview_settings::Status` | `preview-policy-relocation` | planned_unrun |
| `application::relink::Request::Rules` | `application::dto::Response::{Relink}; application::relink::Response::{Rules}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Begin` | `application::dto::Response::{Relink}; application::relink::Response::{Plan}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Prepare` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Revise` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Plan` | `application::dto::Response::{Relink}; application::relink::Response::{Plan}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Plans` | `application::dto::Response::{Relink}; application::relink::Response::{Plans}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Items` | `application::dto::Response::{Relink}; application::relink::Response::{Items}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Sources` | `application::dto::Response::{Relink}; application::relink::Response::{Sources}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Confirm` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Apply` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Undo` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Mounts` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Original` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Status` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |
| `application::relink::Request::Cancel` | `application::dto::Response::{Relink}; application::relink::Response::{Operation}` | `relink-review-identity` | planned_unrun |

## Concrete lifecycle fixtures

### metadata-resolution

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Retain fixture.png with two XMP title candidates: Camera and Chosen; collect the real VariantKey and metadata revision.
2. Read Identity, paged Fields/Candidates/Sources/Observations/Models/Packets/Decisions/FileInstances and all text/blob/import chunks with page limit 2 and chunk length 16.
3. Resolve the title to Chosen at the recorded revision; repeat with the stale revision.

Required observables:

- Changed.revision advances; Fields resolves title Chosen and both candidates remain auditable.
- Paged/chunk replies preserve offsets, exact bytes and next cursors; stale Resolve cannot change any stored decision.

Fault fixtures:

- Use a foreign catalog token: Reply::Error StaleSession.
- Use page limit 0: InvalidRequest; request bytes over configured cap: ResourceLimit.

### metadata-write-recovery

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Use fixture.png plus fixture.png.xmp containing title Before; record both original hashes.
2. Read Options; Start with InputBegin, append exact UTF8 edit document bytes, InputFinish, Prepare/Review and Commit, then SidecarPlan and SidecarApply using returned token/generation/review digest and attempt.
3. Read InputStatus/Receipt/ReviewFields/Chunk/Plans/Plan/RecoveryEntries; cancel one admitted write and restart the managed session.

Required observables:

- Review title After before publication; Receipt identifies the exact operation and target.
- Source image hash stays equal; successful sidecar write publishes After once; restart preserves plan/recovery evidence.

Fault fixtures:

- Reject stale token/generation/review digest and wrong epoch; no overwrite from a stale review.
- Interrupted publication retains recovery evidence instead of reporting successful rollback.

### organization-revisions

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Import fixture-a.png and fixture-b.png; create flat keyword LensWorks, hierarchical keyword Travel/Paris, synonym LW and collection Picks.
2. Apply rating4, Pick flag, Blue label, add/remove/move keywords and collection member edits using current per-image revision.
3. Begin batch; Append both identities; Seal; Step to completion; read Jobs/Items and Review; exercise Cancel on a second batch.

Required observables:

- Queries return the created exact keyword path, synonym and collection placement.
- Changed revision advances for each accepted edit; Members contains the intended identities, and batch terminal counts equal two targets.

Fault fixtures:

- Stale image revision rejects the edit without changing rating/member rows.
- Collection placement cycle and deleting an in-use keyword fail; current rows remain unchanged.

### relink-review-identity

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Import fixture-a.png at root-A, record source hashes; copy exact bytes to root-B, then move root-A aside.
2. Read Rules; Begin with asset scope; Prepare root-B; page Plans/Items/Sources; revise or Confirm with the returned plan revision.
3. Apply, poll Status, query Original/Mounts, then Undo; Cancel an independently preparing plan.

Required observables:

- Review identifies matching fingerprints and the chosen lossless NativePath.
- Apply changes catalog locators only; Undo restores prior locator authority; both original copies keep their hashes.

Fault fixtures:

- Changed candidate bytes or stale plan revision prevents Apply.
- Ambiguous candidates remain unresolved until explicit review; cancellation preserves the previous mapping.

### adjustment-transfer

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Import two images and save source exposure1.25/contrast0.2; target exposure-0.5/contrast-0.1.
2. Begin selecting only Exposure; Append target at real expected revision; Seal with exact total; Inspect and Run; read Jobs/Items.
3. Cancel a second queued job and reopen catalog to inspect persistent job.

Required observables:

- Target exposure becomes1.25 and contrast remains-0.1; target edit revision advances once.
- Inspection digest binds the source recipe and selected groups; terminal item counts reflect applied/skipped/conflicted outcomes.

Fault fixtures:

- Mutate target recipe after Append; Run reports conflict and preserves newer target.
- Active cancellation requires the matching operation id; no overwrite of newer edits.

### preview-policy-relocation

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Read Status and SetBudgets with explicit nonzero proxy/thumbnail budgets from Options-compatible bounds.
2. BeginOriginalRootReview with source root, step exact returned review token with directories2 to completion.
3. BeginRelocation for thumbnail then large tier to empty cache-B; step tier with objects2 and explicit byte allowance and poll Status; restart.

Required observables:

- Status reflects supplied budgets and original-root review progress.
- Completed relocation changes the selected tier root; retained items remain discoverable and originals stay outside cache roots.

Fault fixtures:

- Overlapping original/cache roots reject admission.
- Stale original-root review token or changed storage epoch cannot validate another mapping; StepRelocation selects exact tier.

### guarded-migration

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Create a tiny closed Lightroom SQLite fixture and use retained worker fixture documents for every Operation/InputRole.
2. Begin with exact PartDescriptor byte lengths/digests; Upload ordered UTF8 fragments; Finish each role with computed BLAKE3; Act; poll Status and ResultPage.
3. Cancel before completion, RetryDrain when required, and Discard only the matching returned Guard; restart and review persisted destination.

Required observables:

- Exact Guard/generation remains attached to progress and result pages; uploaded byte totals match documents.
- Migration result identities and catalogs preserve supported metadata, collections, history and provenance from the declared documents.

Fault fixtures:

- Wrong offset, byte total, digest, role, operation or Guard fails before migration authority is admitted.
- Cancel with uncertain drain reports DrainPending; no false successful close/discard.

### workbench-input-review

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Use read-only Workbench on a tiny closed Lightroom SQLite fixture; Open returns real workbench/generation; read Options and Status.
2. Exercise every Action and Query with the required returned revision/evidence; upload Inventory, SelectionRequest, Approval and ApprovalDraft via InputBegin/Append/Finish.
3. Read Result/SealedDocument/ArtifactPreparation using real tokens and digest approvals; InputDiscard, Cancel and Close; retain source hash.

Required observables:

- Queries return bounded rows/chunks under exact selected revision; flattened ResultPage roundtrips without a page key.
- PrepareSelection/Seal require matching review token and approval digest; closed source catalog bytes remain identical.

Fault fixtures:

- Stale workbench/generation/evidence or wrong input offset rejects the action.
- Open read-only never writes source SQLite; Cancel/Close drains before releasing authority.

### export-staging-recovery

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Import a tiny RGBA float-capable fixture, record original BLAKE3; read Options, admit an ICC Profile and release it after use.
2. Begin; resolve Paths/Destinations/DestinationRows; Append a target with exact revision and explicit OutputSize/OutputFormat/Profile/AlphaPolicy/Metadata; Seal exact total.
3. Run with explicit limits; read Job/Jobs/Items/Plan/PlanChunk/Status; Yield/Cancel a second operation; Recover/RetrySeal/Restore from real recovery authority; release result token.

Required observables:

- Retained exports support PNG8/16, JPEG8 with explicit alpha handling and TIFF8/16/float32; export routes never imply PSD/PSB export.
- Published receipt binds source fingerprint, recipe/metadata digest, original identity and reviewed destination; reopen retains jobs/items and source hash is identical.

Fault fixtures:

- Stale plan authority/source fingerprint or changed destination blocks publication.
- Existing output is preserved when overwrite=false; truncated staged output is recoverable and is never reported complete.

### catalog-open-close

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Create an empty catalog beneath a temporary root; read real Status.catalog token; Close and OpenExisting same root.
2. Query Status from an independent job while another request is pending; release all returned owned buffers and jobs.
3. Close twice according to retained session semantics and drain worker before final handle release.

Required observables:

- Status returns a usable catalog token; reopen preserves schema/version and catalog identity.
- Transport reaches verified Closed after child/process/callback drain; every owned handle has one release.

Fault fixtures:

- Open missing path fails without creating it.
- Wrong catalog token returns StaleSession; request after shutdown reports Closed.

### import-resume

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Create source root with exactly two tiny PNGs plus an unsupported text file and record every file hash.
2. Create catalog; ImportStart; poll ImportStatus; cancel one run via returned import id; reopen and ImportResume the same source.
3. Repeat resume after completion; list Images/Folders.

Required observables:

- Exactly two physical assets are retained; unchanged second resume adds no duplicate image identity.
- Terminal counters distinguish imported/unchanged/failed/skipped/pending previews; all source hashes are unchanged.

Fault fixtures:

- Relative source path is InvalidRequest.
- Overlapping import is Busy; wrong import id cannot cancel another operation.

### backup-restore-held-jobs

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Create catalog with two images and one pending organization/export job; record source and catalog identity.
2. BackupCreate into new bundle; poll BackupStatus; BackupInspect verifies actual receipt; BackupRestore into new destination; open restored destination.
3. RestoreStatus reports held jobs; ResumeRestoredJobs supplies actual restore_id and explicit acknowledgement; cancel a separate backup.

Required observables:

- Backup receipt identifies schema/application/database bytes and BLAKE3; restored images and metadata counts match two.
- Restored pending jobs stay held until explicit matching acknowledgement; backup includes catalog state, not a relocated original copy.

Fault fixtures:

- Wrong restore_id fails; refusal to acknowledge pending jobs leaves jobs held.
- Existing restore destination or altered bundle digest fails without replacing existing catalog.

### browse-edit-history

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Import two fixture images with different ratings/names; Images/Folders paginate with limit1 and returned cursors.
2. Search each nondefault filter and Sort/Direction against known metadata; Image/Variants retain exact master/variant keys.
3. CreateVariant; SaveRecipe exposure1.25 at current revision; Undo; Redo; History; Cull rating4/Blue/Pick using real metadata revision.

Required observables:

- Pages retain both identities exactly once; each filter returns the fixture with matching stored value.
- Save/Undo/Redo bind recipe digests and advance revision; history persists across close/reopen; master original bytes never change.

Fault fixtures:

- Search rating6 or limit0 is InvalidRequest.
- Stale edit/metadata revision cannot overwrite a newer recipe or cull.

### preview-generation-bytes

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Import fixture.png; request thumbnail then proxy with viewport main and increasing generations; poll PreviewStatus.
2. Copy admitted preview bytes into owned buffer; release viewport and cancel the matching ticket; reopen offline original root after retained preview exists.
3. Change exposure and request newer generation; drain old generation deliveries.

Required observables:

- Bytes are routed to exact ticket/key/revision/recipe digest; late prior-generation result cannot replace current preview.
- Offline retained preview remains available with explicit unavailable-original state; browse preview is never accepted as full precision editor input.

Fault fixtures:

- Expired/unknown ticket gives StaleSession.
- Canceled or superseded viewport request cannot deliver current-generation authority.

### source-identity

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Obtain real logical/physical/edit identity through retained Catalog methods.
2. Change recipe/metadata/source observations separately and retry stale CAS.

Required observables:

- Physical fingerprint binds original bytes; logical metadata and edit generations remain independently scoped.
- Stale identity callback is not executed.

Fault fixtures:

- Invalid VariantKey fails; mixed source/image key is rejected.

### full-float-original

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. Use CPU-only native full TIFF decoder with negative/high fractional f32 pixels and known BLAKE3.
2. Apply exact retained recipe renderer and stage to a fresh destination.

Required observables:

- Linear f32 precision survives; provenance and receipt bind actual source and recipe identities.
- Source bytes remain identical and browse JPEG cannot satisfy exact input.

Fault fixtures:

- Wrong fingerprint or decoded allocation limit fails before admission.
- Cancellation/stale source blocks publication.

### wire-conformance

Status: **planned_unrun**. Source baseline: `aff50f15a266ce60b7cc55dbe9d612cab94d50b92fb3c0b6d6a0eec965d1c647`.

1. For every wire case, deserialize into exact Rust application::Request and Swift LWApplicationRequest.
2. Serialize Swift request back and deserialize Rust again; compare typed value via JSON tree, including defaults and flattened fields.

Required observables:

- Every source enum discriminator and associated field survives its exact serde representation.
- Canonical decimal strings and lossless NativePath byte/wide units are preserved.

Fault fixtures:

- Unknown enum discriminator/denied unknown field and noncanonical decimal forms fail.

## Public source identity and full precision seams

| Source symbol | Fixture | Concrete action |
| --- | --- | --- |
| `engines/catalog/src/catalog_edits.rs:559::edit_render_identity` | `source-identity` | Query VariantKey::master(real asset); bind physical_generation, fingerprint, image identity, edit revision and recipe digest. Save exposure1.25 and compare identity before/after; same original fingerprint but new edit revision/digest. Attempt with_edit_identity using stale identity: callback not invoked, result None. |
| `engines/catalog/src/catalog_images.rs:290::image_metadata_identity` | `source-identity` | Query master and created variant separately; metadata edits advance only the applicable image revision. Source observation change advances shared source epoch/physical generation; source hash remains original. |
| `engines/catalog/src/edit/render.rs:212::decode_original` | `full-float-original` | Decode tiny float TIFF with pixels[-0.25,0.5012345,1.25,1.0] under actual expected BLAKE3 and WhiteBalance::AsShot. Assert f32 linear channels retain negative/high values and >8bit fractional precision; exact=true and original dimensions2x2. Wrong fingerprint fails SourceChanged; source file bytes remain unchanged. |
| `engines/catalog/src/media/full.rs:244::decode_full_limited` | `full-float-original` | Decode actual PNG/TIFF fixture under finite DecodeLimits; preserve orientation/color/provenance. Exceed encoded/pixel/allocation limits and assert typed ResourceLimit rather than unbounded allocation. |
| `engines/catalog/src/edit/render.rs:311::render_recipe` | `full-float-original` | Apply validated exposure+1EV to linear[0.25,0.125,0.5,1] original input; expected RGB doubles before output clipping. RenderPurpose::ExportExact must reject proxy-only input; cancellation cannot publish partial current output. |
| `engines/catalog/src/photo_render.rs:88::render_staged_photo` | `full-float-original` | Render verified original to caller-owned fresh stage with PNG/JPEG/TIFF OutputSpec and explicit alpha policy. Compare original BLAKE3 before/after and receipt source_fingerprint, recipe_digest, renderer identity. Changed source/occupied stage/cancel fails without publishing destination. |

Full precision linear f32 decoding and verified source identity are independent public Rust seams; retained preview/browse JPEG or Compositor RGBA8 is insufficient acceptance. PSD/PSB import does not grant an export route. Frozen license/provenance remain in DEPENDENCIES.json and THIRD_PARTY_NOTICES.md.

## Audit contract

Run `python3 scripts/audit-catalog-service-coverage.py --check-swift`. The audit independently extracts module-scope declarations/imports and exact fields/serde tags/macro-expanded limits and decimal wrappers, verifies the owned source digest and file hashes, and rejects missing coverage or changed source authority. It checks actual Swift associated/struct payload types, not just member names. `--self-test-source-resolution` executes lexical-scope/local-shadow/module-alias/reexport-cycle/wildcard-ambiguity regressions, populated generic pages, and negative wrong graph/Swift type bindings. `--write` regenerates source-derived artifacts; none of these commands execute operational acceptance fixtures.

## Source ambiguities and execution limits

All reachable type references resolve. Runtime authority values and lifecycle success are intentionally unresolved until actual fixture setup returns them. Typed Error replies are fault evidence and never count as a successful workflow. Migration Cancel can return Discarded before upload activation; export inactive Cancel returns Job while active Cancel returns Operation. These alternate successful result forms are explicitly retained.

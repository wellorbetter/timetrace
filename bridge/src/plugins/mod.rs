//! Canonical bundled plugin bridge service.

pub(crate) mod service;
mod store;

pub use service::{
    HostContributionSnapshotDto, HostDeclarativeV1DocumentDto, HostDeclarativeV1NodeDto,
    HostPluginUiStateDto, HostProjectedContributionDto, PluginService,
};

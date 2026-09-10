#include <cstdio>
#include "../src/creation_protocol.h"
using namespace creation_protocol;
int main() {
    int checks = 0, failures = 0;
    auto check = [&](bool ok) { ++checks; if (!ok) ++failures; };
    const char* ticket = "0123456789abcdef0123456789abcdef";
    check(validTicket(ticket)); check(!validTicket(nullptr)); check(!validTicket(""));
    check(!validTicket("0123456789ABCDEF0123456789abcdef")); check(!validTicket("x123456789abcdef0123456789abcdef"));
    for (const std::string mode : { "success", "lost-prepare", "bad-prepare", "lost-create", "garbled-create",
                                   "wrong-id", "wrong-ticket", "refused", "conflict", "pending-conflict", "legacy", "legacy-conflict" }) {
        agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
        agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
        req.which_cmd = agwinterm_ptyhost_Request_create_tag; strcpy_s(req.cmd.create.id, "pane");
        int prepares = 0, creates = 0, cancels = 0;
        bool legacy = mode == "legacy" || mode == "legacy-conflict";
        auto result = start(!legacy, req, rep, [&](const auto& command, auto& reply, Outcome& outcome) {
            outcome = Outcome::NoReply;
            if (command.which_cmd == agwinterm_ptyhost_Request_prepare_create_tag) {
                ++prepares; if (mode == "lost-prepare") return false;
                check(std::strcmp(command.cmd.prepare_create.id, "pane") == 0);
                reply.which_body = agwinterm_ptyhost_Reply_creation_tag;
                strcpy_s(reply.body.creation.id, "pane"); strcpy_s(reply.body.creation.ticket, mode == "bad-prepare" ? "bad" : ticket);
                reply.body.creation.phase = agwinterm_ptyhost_CreationPhase_CREATION_PREPARED;
            } else {
                ++creates; check(command.which_cmd == agwinterm_ptyhost_Request_create_tag);
                check(std::strcmp(command.cmd.create.creation_ticket, legacy ? "" : ticket) == 0);
                if (mode == "lost-create") return false;
                if (mode == "garbled-create") { outcome = Outcome::Undecodable; return false; }
                if (mode == "refused" || mode == "conflict" || mode == "pending-conflict" || mode == "legacy-conflict") {
                    outcome = Outcome::Refused; strcpy_s(reply.error, mode == "refused" ? "spawn failed" : "session already exists"); return false;
                }
                reply.which_body = agwinterm_ptyhost_Reply_create_tag;
                strcpy_s(reply.body.create.id, mode == "wrong-id" ? "other" : "pane");
                strcpy_s(reply.body.create.creation_ticket, mode == "wrong-ticket" ? "other" : ticket);
            }
            outcome = Outcome::Ok; return true;
        }, [&](const char* id, const char* expected) {
            ++cancels; check(std::strcmp(id, "pane") == 0); check(std::strcmp(expected, ticket) == 0);
            return mode != "pending-conflict";
        });
        bool noCreate = mode == "lost-prepare" || mode == "bad-prepare";
        bool success = mode == "success" || mode == "legacy";
        check(prepares == (legacy ? 0 : 1)); check(creates == (noCreate ? 0 : 1));
        check(cancels == (noCreate || success || legacy ? 0 : 1));
        check(result.status == (success ? Status::Created : mode == "conflict" || mode == "legacy-conflict" ? Status::Conflict : Status::Failed));
    }
    for (const std::string mode : { "same", "wrong-host", "zero-host", "legacy-host", "wrong-protocol", "wrong-body", "lost-hello" }) {
        int calls = 0;
        bool bound = bindCancellationHost(mode == "zero-host" ? 0 : 123, 2, [&](const auto& req, auto& reply) {
            ++calls; check(req.which_cmd == agwinterm_ptyhost_Request_hello_tag && req.cmd.hello.protocol == 2);
            reply.which_body = mode == "wrong-body" ? agwinterm_ptyhost_Reply_creation_tag : agwinterm_ptyhost_Reply_hello_tag;
            reply.body.hello.protocol = mode == "wrong-protocol" ? 3 : 2;
            reply.body.hello.pid = mode == "wrong-host" ? 456 : 123;
            reply.body.hello.creation_revision = mode == "legacy-host" ? 0 : 1;
            return mode != "lost-hello";
        });
        check(bound == (mode == "same")); check(calls == (mode == "zero-host" ? 0 : 1));
    }
    std::printf("creation protocol: %d checks, %d failed; fake exchange only\n", checks, failures);
    return failures ? 1 : 0;
}

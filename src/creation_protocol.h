#pragma once
#include <cstring>
#include <string>
#include "proto/ptyhost.pb.h"

namespace creation_protocol {
enum class Outcome { NoReply, Undecodable, Refused, Ok };
enum class Status { Failed, Conflict, Created };
struct Result { Status status = Status::Failed; std::string ticket; };
inline bool validTicket(const char* ticket) {
    if (!ticket || std::strlen(ticket) != 32) return false;
    for (const char* p = ticket; *p; ++p)
        if (!(*p >= '0' && *p <= '9') && !(*p >= 'a' && *p <= 'f')) return false;
    return true;
}

// This function issues at most one Create. Only a proven explicit ID conflict can authorize the
// caller to choose a different ID; a lost response never does, even if cleanup later succeeds.
template<class Exchange, class Cancel>
Result start(bool capable, agwinterm_ptyhost_Request& create, agwinterm_ptyhost_Reply& reply,
             Exchange exchange, Cancel cancel) {
    Result result;
    const char* id = create.cmd.create.id;
    if (capable) {
        agwinterm_ptyhost_Request prepare = agwinterm_ptyhost_Request_init_default;
        agwinterm_ptyhost_Reply prepared = agwinterm_ptyhost_Reply_init_default;
        prepare.which_cmd = agwinterm_ptyhost_Request_prepare_create_tag;
        strcpy_s(prepare.cmd.prepare_create.id, id);
        Outcome outcome;
        if (!exchange(prepare, prepared, outcome) || prepared.which_body != agwinterm_ptyhost_Reply_creation_tag ||
            std::strcmp(prepared.body.creation.id, id) ||
            prepared.body.creation.phase != agwinterm_ptyhost_CreationPhase_CREATION_PREPARED ||
            !validTicket(prepared.body.creation.ticket)) return result;
        result.ticket = prepared.body.creation.ticket;
    }
    strcpy_s(create.cmd.create.creation_ticket, result.ticket.c_str());
    Outcome outcome = Outcome::NoReply;
    bool created = exchange(create, reply, outcome);
    if (created && reply.which_body == agwinterm_ptyhost_Reply_create_tag &&
        std::strcmp(reply.body.create.id, id) == 0 &&
        (result.ticket.empty() || result.ticket == reply.body.create.creation_ticket)) {
        result.status = Status::Created;
        return result;
    }
    bool cleaned = result.ticket.empty() || cancel(id, result.ticket.c_str());
    if (cleaned && outcome == Outcome::Refused && std::strstr(reply.error, "already exists"))
        result.status = Status::Conflict;
    return result;
}
}

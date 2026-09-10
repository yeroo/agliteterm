#pragma once
#include <algorithm>
#include <cstdint>
#include <initializer_list>
#include <string>
#include <vector>

// Process-local identity alongside the persisted names/indexes. Callers hold g_lock.
// Renaming/reindexing cannot redirect an in-flight create or an undo-close to another workspace.
class WorkspaceNames {
    std::vector<std::wstring> names_;
    std::vector<uint64_t> tokens_;
    uint64_t next_ = 1;
public:
    using iterator = std::vector<std::wstring>::iterator;
    WorkspaceNames(std::initializer_list<std::wstring> names) { for (const auto& name : names) push_back(name); }
    size_t size() const { return names_.size(); }
    std::wstring& operator[](size_t i) { return names_[i]; }
    const std::wstring& operator[](size_t i) const { return names_[i]; }
    iterator begin() { return names_.begin(); }
    iterator end() { return names_.end(); }
    auto begin() const { return names_.begin(); }
    auto end() const { return names_.end(); }
    void push_back(const std::wstring& name) { names_.push_back(name); tokens_.push_back(next_++); }
    void erase(iterator at) { const auto index = at - names_.begin(); tokens_.erase(tokens_.begin() + index); names_.erase(at); }
    void move(int from, int to) {
        if (from < to) {
            std::rotate(names_.begin() + from, names_.begin() + from + 1, names_.begin() + to + 1);
            std::rotate(tokens_.begin() + from, tokens_.begin() + from + 1, tokens_.begin() + to + 1);
        } else if (from > to) {
            std::rotate(names_.begin() + to, names_.begin() + from, names_.begin() + from + 1);
            std::rotate(tokens_.begin() + to, tokens_.begin() + from, tokens_.begin() + from + 1);
        }
    }
    WorkspaceNames& operator=(const std::vector<std::wstring>& names) {
        names_ = names; tokens_.clear(); for (size_t i = 0; i < names.size(); ++i) tokens_.push_back(next_++);
        return *this;
    }
    uint64_t token(int index) const { return index >= 0 && static_cast<size_t>(index) < tokens_.size() ? tokens_[index] : 0; }
    int index(uint64_t token) const {
        const auto at = std::find(tokens_.begin(), tokens_.end(), token);
        return at == tokens_.end() ? -1 : static_cast<int>(at - tokens_.begin());
    }
    // Deleting a workspace moves its sessions to the first workspace; late publication follows it.
    int destination(uint64_t token) const { const int found = index(token); return found >= 0 ? found : 0; }
};

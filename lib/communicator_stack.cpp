#include <communicator_quda.h>
#include <map>
#include <array>

std::map<CommKey, Communicator> communicator_stack;

Communicator *current_communicator = nullptr;

static void print(const CommKey &key) { printf("%3dx%3dx%3dx%3d", key[0], key[1], key[2], key[3]); }

constexpr CommKey default_key = {1, 1, 1, 1};

CommKey current_key = {-1, -1, -1, -1};

void init_communicator_stack(int ndim, const int *dims, QudaCommsMap rank_from_coords, void *map_data, bool user_set_comm_handle, void *user_comm)
{
  communicator_stack.emplace(std::piecewise_construct, std::forward_as_tuple(default_key),
                             std::forward_as_tuple(ndim, dims, rank_from_coords, map_data, user_set_comm_handle, user_comm));

  current_key = default_key;
}

void finalize_communicator_stack() { communicator_stack.clear(); }

static Communicator &get_default_communicator()
{
  auto search = communicator_stack.find(default_key);
  if (search != communicator_stack.end()) {
    return search->second;
  } else {
    assert(false);
  }
}

Communicator &get_current_communicator()
{
  auto search = communicator_stack.find(current_key);
  if (search != communicator_stack.end()) {
    return search->second;
  } else {
    assert(false);
  }
}

void push_to_current(const CommKey &split_key)
{
  auto search = communicator_stack.find(split_key);
  if (search != communicator_stack.end()) {

    printf("Found communicator for key ");
    print(split_key);
    printf(".\n");

  } else {

    communicator_stack.emplace(std::piecewise_construct, std::forward_as_tuple(split_key),
                               std::forward_as_tuple(get_default_communicator(), split_key.data()));

    printf("Communicator for key ");
    print(split_key);
    printf(" added.\n");
  }

  current_key = split_key;
}

int comm_neighbor_rank(int dir, int dim){
  return get_default_communicator().comm_neighbor_rank(dir, dim);
}

int comm_dim(int dim) { return get_current_communicator().comm_dim(dim); }

int comm_coord(int dim) { return get_current_communicator().comm_coord(dim); }

void comm_init(int ndim, const int *dims, QudaCommsMap rank_from_coords, void *map_data, bool user_set_comm_handle, void *user_comm)
{
  init_communicator_stack(ndim, dims, rank_from_coords, map_data, user_set_comm_handle, user_comm);
}

void comm_finalize() { finalize_communicator_stack(); }

void comm_dim_partitioned_set(int dim) { get_current_communicator().comm_dim_partitioned_set(dim); }

void comm_dim_partitioned_reset() { get_current_communicator().comm_dim_partitioned_reset(); }

int comm_dim_partitioned(int dim) { return get_current_communicator().comm_dim_partitioned(dim); }

int comm_partitioned() { return get_current_communicator().comm_partitioned(); }

const char *comm_dim_topology_string() { return get_current_communicator().topology_string; }

int comm_rank(void) { return get_current_communicator().comm_rank(); }

int comm_size(void) { return get_current_communicator().comm_size(); }

// XXX:
// Note here we are always using the **default** communicator.
// We might need to have a better approach.
int comm_gpuid(void) { return get_default_communicator().comm_gpuid(); }

bool comm_deterministic_reduce() { return get_current_communicator().comm_deterministic_reduce(); }

void comm_gather_hostname(char *hostname_recv_buf)
{
  get_current_communicator().comm_gather_hostname(hostname_recv_buf);
}

void comm_gather_gpuid(int *gpuid_recv_buf) { get_current_communicator().comm_gather_gpuid(gpuid_recv_buf); }

#if 0

  /**
     Enabled peer-to-peer communication.
     @param hostname_buf Array that holds all process hostnames
   */
  void comm_peer2peer_init(const char *hostname_recv_buf);

#endif

bool comm_peer2peer_present() { return get_current_communicator().comm_peer2peer_present(); }

int comm_peer2peer_enabled_global() { return get_current_communicator().comm_peer2peer_enabled_global(); }

bool comm_peer2peer_enabled(int dir, int dim) { return get_current_communicator().comm_peer2peer_enabled(dir, dim); }

void comm_enable_peer2peer(bool enable) { get_current_communicator().comm_enable_peer2peer(enable); }

bool comm_intranode_enabled(int dir, int dim) { return get_current_communicator().comm_intranode_enabled(dir, dim); }

void comm_enable_intranode(bool enable) { get_current_communicator().comm_enable_intranode(enable); }

bool comm_gdr_enabled() { return get_current_communicator().comm_gdr_enabled(); }

bool comm_gdr_blacklist() { return get_current_communicator().comm_gdr_blacklist(); }

MsgHandle *comm_declare_send_displaced(void *buffer, const int displacement[], size_t nbytes)
{
  return get_current_communicator().comm_declare_send_displaced(buffer, displacement, nbytes);
}

MsgHandle *comm_declare_receive_displaced(void *buffer, const int displacement[], size_t nbytes)
{
  return get_current_communicator().comm_declare_receive_displaced(buffer, displacement, nbytes);
}

MsgHandle *comm_declare_strided_send_displaced(void *buffer, const int displacement[], size_t blksize, int nblocks,
                                               size_t stride)
{
  return get_current_communicator().comm_declare_strided_send_displaced(buffer, displacement, blksize, nblocks, stride);
}

MsgHandle *comm_declare_strided_receive_displaced(void *buffer, const int displacement[], size_t blksize, int nblocks,
                                                  size_t stride)
{
  return get_current_communicator().comm_declare_strided_receive_displaced(buffer, displacement, blksize, nblocks,
                                                                           stride);
}

void comm_free(MsgHandle *&mh) { get_current_communicator().comm_free(mh); }

void comm_start(MsgHandle *mh) { get_current_communicator().comm_start(mh); }

void comm_wait(MsgHandle *mh) { get_current_communicator().comm_wait(mh); }

int comm_query(MsgHandle *mh) { return get_current_communicator().comm_query(mh); }

void comm_allreduce(double *data) { get_current_communicator().comm_allreduce(data); }

void comm_allreduce_max(double *data) { get_current_communicator().comm_allreduce_max(data); }

void comm_allreduce_min(double *data) { get_current_communicator().comm_allreduce_min(data); }

void comm_allreduce_array(double *data, size_t size) { get_current_communicator().comm_allreduce_array(data, size); }

void comm_allreduce_max_array(double *data, size_t size)
{
  get_current_communicator().comm_allreduce_max_array(data, size);
}

void comm_allreduce_int(int *data) { get_current_communicator().comm_allreduce_int(data); }

void comm_allreduce_xor(uint64_t *data) { get_current_communicator().comm_allreduce_xor(data); }

void comm_broadcast(void *data, size_t nbytes) { get_current_communicator().comm_broadcast(data, nbytes); }

void comm_barrier(void) { get_current_communicator().comm_barrier(); }

void comm_abort_(int status) { get_current_communicator().comm_abort_(status); };

void reduceMaxDouble(double &max) { get_current_communicator().reduceMaxDouble(max); }

void reduceDouble(double &sum) { get_current_communicator().reduceDouble(sum); }

void reduceDoubleArray(double *max, const int len) { get_current_communicator().reduceDoubleArray(max, len); }

int commDim(int dim) { return get_current_communicator().commDim(dim); }

int commCoords(int dim) { return get_current_communicator().commCoords(dim); }

int commDimPartitioned(int dir) { return get_current_communicator().commDimPartitioned(dir); }

void commDimPartitionedSet(int dir) { get_current_communicator().commDimPartitionedSet(dir); }

void commDimPartitionedReset() { get_current_communicator().commDimPartitionedReset(); }

bool commGlobalReduction() { return get_current_communicator().commGlobalReduction(); }

void commGlobalReductionSet(bool global_reduce) { get_current_communicator().commGlobalReductionSet(global_reduce); }

bool commAsyncReduction() { return get_current_communicator().commAsyncReduction(); }

void commAsyncReductionSet(bool global_reduce) { get_current_communicator().commAsyncReductionSet(global_reduce); }
